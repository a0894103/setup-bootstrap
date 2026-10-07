import http from 'node:http';
import { spawn, execFile } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

// ----------------------------------------------------
// 參數處理
// ----------------------------------------------------
const args = process.argv.slice(2);
let serverPort = 8765;
let configPathArg = null;

for (let i = 0; i < args.length; i++) {
  if (args[i] === '--port' && i + 1 < args.length) {
    serverPort = parseInt(args[++i], 10) || 8765;
  } else if (args[i] === '--config' && i + 1 < args.length) {
    configPathArg = args[++i];
  }
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const defaultConfigFile = path.resolve(__dirname, 'console.json');
const activeConfigPath = configPathArg ? path.resolve(process.cwd(), configPathArg) : defaultConfigFile;

// ----------------------------------------------------
// 環境變數展開與設定檔讀取
// ----------------------------------------------------
function expandEnv(str) {
  if (typeof str !== 'string') return str;
  return str.replace(/%([^%]+)%/g, (_, name) => {
    return process.env[name] ?? process.env[name.toUpperCase()] ?? '';
  });
}

function expandConfig(rawConfig) {
  const result = JSON.parse(JSON.stringify(rawConfig));
  for (const key of Object.keys(result)) {
    if (typeof result[key] === 'string') {
      result[key] = expandEnv(result[key]);
    }
  }
  return result;
}

function loadConfig() {
  const content = fs.readFileSync(activeConfigPath, 'utf8');
  return expandConfig(JSON.parse(content));
}

// ----------------------------------------------------
// 背景工作管理 (Jobs)
// ----------------------------------------------------
const jobs = [];
let ghLoginCode = null;
let codexLogin = null;
let codexChild = null;

function appendToConsoleJobLog(stateDir, text) {
  if (!stateDir) return;
  try {
    if (!fs.existsSync(stateDir)) {
      fs.mkdirSync(stateDir, { recursive: true });
    }
    const logPath = path.join(stateDir, 'console-jobs.log');
    fs.appendFileSync(logPath, text, 'utf8');
  } catch {
    // 忽略寫檔錯誤
  }
}

function createJob(action, stateDir) {
  const job = {
    id: `job_${Date.now()}_${Math.random().toString(36).slice(2, 7)}`,
    action,
    startedAt: new Date().toISOString(),
    endedAt: null,
    exitCode: null,
    lines: []
  };
  jobs.unshift(job);
  if (jobs.length > 20) {
    jobs.pop();
  }
  appendToConsoleJobLog(stateDir, `\n[${job.startedAt}] [START] Job ${job.id} (${action})\n`);
  return job;
}

function appendJobOutput(job, stateDir, chunk) {
  const str = typeof chunk === 'string' ? chunk : chunk.toString('utf8');
  const lines = str.split(/\r?\n/);
  for (const line of lines) {
    if (!line && lines.length === 1) continue;
    job.lines.push(line);
    if (job.lines.length > 500) {
      job.lines.shift();
    }
  }
  appendToConsoleJobLog(stateDir, str);
}

function finishJob(job, stateDir, code) {
  job.endedAt = new Date().toISOString();
  job.exitCode = code;
  appendToConsoleJobLog(stateDir, `\n[${job.endedAt}] [END] Job ${job.id} (${job.action}) exit ${code}\n`);
}

function isActionRunning(action) {
  return jobs.some(j => j.action === action && j.endedAt === null);
}

// ----------------------------------------------------
// 檢查與探測輔助函式
// ----------------------------------------------------
// Chrome "On startup: continue where you left off" (session.restore_on_startup = 1) so LINE etc. stay logged in.
// Only edited while that Chrome profile is not running (a running Chrome would overwrite the file).
function setRestoreOnStartup(userDataDir) {
  try {
    const dir = path.join(userDataDir, 'Default');
    fs.mkdirSync(dir, { recursive: true });
    const pref = path.join(dir, 'Preferences');
    let j = {};
    if (fs.existsSync(pref)) { try { j = JSON.parse(fs.readFileSync(pref, 'utf8')); } catch { return false; } }
    j.session = j.session || {};
    j.session.restore_on_startup = 1;
    fs.writeFileSync(pref, JSON.stringify(j));
    return true;
  } catch { return false; }
}

// running Chrome instances: CDP ports in use, and whether the main (default profile) Chrome is open
let chromeScanCache = null; let chromeScanTime = 0;
function scanChromes() {
  if (chromeScanCache && Date.now() - chromeScanTime < 5000) return Promise.resolve(chromeScanCache);
  return new Promise((resolve) => {
    const ps = "Get-CimInstance Win32_Process -Filter \"Name='chrome.exe'\" | Where-Object { $_.CommandLine -notmatch '--type=' } | ForEach-Object { $_.CommandLine }";
    execFile('powershell.exe', ['-NoProfile', '-Command', ps], { timeout: 15000, windowsHide: true }, (err, stdout) => {
      const lines = String(stdout || '').split(/\r?\n/).filter(Boolean);
      const ports = new Set(); let main = false;
      for (const l of lines) {
        const mm = l.match(/--remote-debugging-port=(\d+)/);
        if (mm) ports.add(Number(mm[1]));
        else if (!/--user-data-dir=/.test(l)) main = true;
      }
      chromeScanCache = { ports: [...ports].sort((a, b) => a - b), mainRunning: main };
      chromeScanTime = Date.now();
      resolve(chromeScanCache);
    });
  });
}
async function probeChrome(port) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 800);
  try {
    const res = await fetch(`http://127.0.0.1:${port}/json/version`, {
      signal: controller.signal
    });
    clearTimeout(timer);
    return res.ok;
  } catch {
    clearTimeout(timer);
    return false;
  }
}

function checkGhAuth(ghExe) {
  return new Promise((resolve) => {
    if (!ghExe || !fs.existsSync(ghExe)) {
      return resolve({ installed: false, loggedIn: false, accounts: [] });
    }
    execFile(ghExe, ['auth', 'status'], { timeout: 10000 }, (error, stdout, stderr) => {
      const output = (stdout || '') + '\n' + (stderr || '');
      const accounts = [];
      const lines = output.split(/\r?\n/);
      for (const line of lines) {
        // 匹配 "Logged in to github.com account <username>" 或 "as <username>"
        const match = line.match(/(?:Logged in to [^\s]+ (?:account|as)|(?:account|as))\s+([A-Za-z0-9_.-]+)/i);
        if (match && match[1]) {
          const acc = match[1].trim();
          // 過濾非帳號的關鍵字如 true, https, token 等
          if (!['true', 'false', 'https', 'ssh', 'token', 'keyring'].includes(acc.toLowerCase())) {
            if (!accounts.includes(acc)) {
              accounts.push(acc);
            }
          }
        }
      }
      resolve({
        installed: true,
        loggedIn: accounts.length > 0,
        accounts
      });
    });
  });
}

// Open a visible PowerShell window running psCommand (paths in psCommand use single quotes).
// windowsVerbatimArguments: Node must not re-quote, otherwise cmd sees \"...\" and fails.
function openVisible(title, psCommand) {
  const line = `start "${title}" powershell.exe -NoExit -ExecutionPolicy Bypass -Command "${psCommand}"`;
  const child = spawn('cmd.exe', ['/d', '/s', '/c', line], {
    detached: true, stdio: 'ignore', windowsHide: false, windowsVerbatimArguments: true
  });
  child.unref();
}
function checkClaude(claudeExe, claudeSeat2Dir) {
  const userProfile = process.env.USERPROFILE || '';
  const seat1Path = path.join(userProfile, '.claude', '.credentials.json');
  const seat2Path = path.join(claudeSeat2Dir || '', '.credentials.json');
  return {
    installed: Boolean(claudeExe && fs.existsSync(claudeExe)),
    seat1: Boolean(fs.existsSync(seat1Path)),
    seat2: Boolean(claudeSeat2Dir && fs.existsSync(seat2Path))
  };
}

function checkCodex(codexCmd) {
  // logged in = %USERPROFILE%\.codex\auth.json exists (existence only, never read)
  const authPath = path.join(process.env.USERPROFILE || '', '.codex', 'auth.json');
  return {
    installed: Boolean(codexCmd && fs.existsSync(codexCmd)),
    loggedIn: fs.existsSync(authPath)
  };
}

function checkRepo(repoDir) {
  const gitDir = repoDir ? path.join(repoDir, '.git') : '';
  return {
    dir: repoDir || '',
    cloned: Boolean(gitDir && fs.existsSync(gitDir))
  };
}

const APP_DETECT_COMMANDS = {
  antigravity: "[bool](Get-ItemProperty HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*,HKLM:\\Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*,HKLM:\\Software\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\* -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match '^Antigravity' })",
  codex: "[bool](Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue)",
  claude: "[bool](Get-AppxPackage -Name 'Claude' -ErrorAction SilentlyContinue)"
};

function checkAppInstalled(appId) {
  const psCmd = APP_DETECT_COMMANDS[appId];
  if (!psCmd) return Promise.resolve(false);
  return new Promise((resolve) => {
    execFile('powershell.exe', ['-NoProfile', '-Command', psCmd], { timeout: 15000 }, (err, stdout) => {
      if (err) return resolve(false);
      const val = (stdout || '').trim().toLowerCase();
      resolve(val === 'true');
    });
  });
}

function checkWingetAvailable() {
  return new Promise((resolve) => {
    execFile('where.exe', ['winget'], { timeout: 5000 }, (err, stdout) => {
      resolve(!err && (stdout || '').trim().length > 0);
    });
  });
}

function checkDevMode() {
  return new Promise((resolve) => {
    execFile('reg.exe', ['query', 'HKLM\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\AppModelUnlock', '/v', 'AllowDevelopmentWithoutDevLicense'], { timeout: 5000 }, (err, stdout) => {
      resolve(!err && /0x1\b/.test(stdout || ''));
    });
  });
}

function checkCoworkService() {
  return new Promise((resolve) => {
    execFile('sc.exe', ['qc', 'CoworkVMService'], { timeout: 5000 }, (err, stdout) => {
      const output = (stdout || '');
      const exists = !err && output.includes('SERVICE_NAME');
      const disabled = exists && /START_TYPE[^\r\n]*DISABLED/i.test(output);
      resolve({ exists: Boolean(exists), disabled: Boolean(disabled) });
    });
  });
}

let appStatusCache = null;
let appStatusCacheTime = 0;
let appStatusInFlight = null;
const APP_STATUS_CACHE_TTL_MS = 10000;

function invalidateAppStatusCache() {
  appStatusCache = null;
  appStatusCacheTime = 0;
}

async function getAppsAndCoworkStatus(appsConfig) {
  const now = Date.now();
  if (appStatusCache && (now - appStatusCacheTime < APP_STATUS_CACHE_TTL_MS)) {
    return appStatusCache;
  }
  if (appStatusInFlight) {
    return appStatusInFlight;
  }

  appStatusInFlight = (async () => {
    try {
      const wingetAvailable = await checkWingetAvailable();
      const appsList = appsConfig || [];
      const [appResults, cowork, devMode] = await Promise.all([
        Promise.all(appsList.map(async (app) => {
          const installed = await checkAppInstalled(app.id);
          return {
            id: app.id,
            label: app.label,
            optional: Boolean(app.optional),
            installed: Boolean(installed),
            wingetAvailable: Boolean(wingetAvailable)
          };
        })),
        checkCoworkService(),
        checkDevMode()
      ]);

      const result = {
        apps: appResults,
        cowork,
        devMode
      };
      appStatusCache = result;
      appStatusCacheTime = Date.now();
      return result;
    } finally {
      appStatusInFlight = null;
    }
  })();

  return appStatusInFlight;
}

function readJsonFile(filePath) {
  try {
    if (!fs.existsSync(filePath)) return [];
    const content = fs.readFileSync(filePath, 'utf8');
    const data = JSON.parse(content);
    return Array.isArray(data) ? data : [];
  } catch {
    return [];
  }
}

function readLogTail(filePath, maxLines = 80) {
  try {
    if (!fs.existsSync(filePath)) return [];
    const content = fs.readFileSync(filePath, 'utf8');
    const lines = content.split(/\r?\n/);
    while (lines.length > 0 && lines[lines.length - 1] === '') {
      lines.pop();
    }
    return lines.slice(-maxLines);
  } catch {
    return [];
  }
}

// ----------------------------------------------------
// 安全檢查 (Origin / Host 驗證)
// ----------------------------------------------------
function checkSecurityHeaders(req, currentPort) {
  const origin = req.headers['origin'];
  const host = req.headers['host'];

  const allowedOrigins = [
    `http://127.0.0.1:${currentPort}`,
    `http://localhost:${currentPort}`
  ];
  const allowedHosts = [
    `127.0.0.1:${currentPort}`,
    `localhost:${currentPort}`
  ];

  if (origin) {
    return allowedOrigins.includes(origin);
  }
  if (host) {
    return allowedHosts.includes(host);
  }
  return false;
}

function sendJson(res, statusCode, data) {
  const json = JSON.stringify(data);
  res.writeHead(statusCode, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(json)
  });
  res.end(json);
}

function parseJsonBody(req) {
  return new Promise((resolve, reject) => {
    let raw = '';
    req.on('data', chunk => {
      raw += chunk.toString('utf8');
      if (raw.length > 1e6) {
        req.destroy();
        reject(new Error('Payload too large'));
      }
    });
    req.on('end', () => {
      if (!raw.trim()) {
        return resolve({});
      }
      try {
        resolve(JSON.parse(raw));
      } catch (err) {
        reject(err);
      }
    });
    req.on('error', reject);
  });
}

// ----------------------------------------------------
// HTTP 伺服器
// ----------------------------------------------------
const server = http.createServer(async (req, res) => {
  const urlObj = new URL(req.url, `http://127.0.0.1:${serverPort}`);
  const pathname = urlObj.pathname;

  // 1. GET / -> index.html
  if (req.method === 'GET' && pathname === '/') {
    const indexPath = path.resolve(__dirname, 'index.html');
    if (!fs.existsSync(indexPath)) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      return res.end('index.html not found');
    }
    const html = fs.readFileSync(indexPath, 'utf8');
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(html);
  }

  // 2. GET /api/status
  if (req.method === 'GET' && pathname === '/api/status') {
    let config;
    try {
      config = loadConfig();
    } catch (err) {
      return sendJson(res, 500, { error: `載入設定檔失敗: ${err.message}` });
    }

    const stateDir = config.stateDir || '';
    const setupResultsPath = path.join(stateDir, 'setup-results.json');
    const verifyResultsPath = path.join(stateDir, 'verify-results.json');
    const setupLogPath = path.join(stateDir, 'setup.log');

    const steps = readJsonFile(setupResultsPath);
    const verify = readJsonFile(verifyResultsPath);
    const logTail = readLogTail(setupLogPath, 80);

    const chromes = await scanChromes();

    const gh = await checkGhAuth(config.ghExe);
    const claude = checkClaude(config.claudeExe, config.claudeSeat2Dir);
    const codex = checkCodex(config.codexCmd);
    const repo = checkRepo(config.repoDir);
    const { apps, cowork, devMode } = await getAppsAndCoworkStatus(config.apps);

    const serializedJobs = jobs.map(j => ({
      id: j.id,
      action: j.action,
      startedAt: j.startedAt,
      endedAt: j.endedAt,
      exitCode: j.exitCode,
      outputTail: j.lines.slice(-30)
    }));

    return sendJson(res, 200, {
      steps,
      verify,
      logTail,
      chromes,
      gh,
      claude,
      codex,
      repo,
      jobs: serializedJobs,
      devMode,
      codexLogin,
      ghLoginCode,
      apps,
      cowork
    });
  }

  // 3. POST /api/action
  if (req.method === 'POST' && pathname === '/api/action') {
    // 安全檢查：Origin / Host 驗證
    if (!checkSecurityHeaders(req, serverPort)) {
      return sendJson(res, 403, { error: 'Forbidden' });
    }

    let body;
    try {
      body = await parseJsonBody(req);
    } catch {
      return sendJson(res, 400, { error: 'Invalid JSON body' });
    }

    const action = body.action;
    const ALLOWED_ACTIONS = new Set([
      'run-setup',
      'run-verify',
      'open-chrome',
      'gh-login',
      'clone-repo',
      'claude-login-seat1',
      'claude-login-seat2',
      'codex-login',
      'svn-continue',
      'install-app',
      'disable-cowork',
      'enable-devmode',
      'open-app'
    ]);

    if (!ALLOWED_ACTIONS.has(action)) {
      return sendJson(res, 400, { error: 'Invalid action' });
    }

    let config;
    try {
      config = loadConfig();
    } catch (err) {
      return sendJson(res, 500, { error: `載入設定檔失敗: ${err.message}` });
    }

    // 處理 action
    switch (action) {
      case 'run-setup': {
        if (isActionRunning('run-setup')) {
          return sendJson(res, 200, { running: true });
        }
        const job = createJob('run-setup', config.stateDir);
        const child = spawn('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-File', config.setupScript,
          '-Roles', config.roles,
          '-LogDir', config.stateDir
        ], {
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe']
        });
        child.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.on('close', code => finishJob(job, config.stateDir, code));
        return sendJson(res, 200, { started: true, jobId: job.id });
      }

      case 'run-verify': {
        if (isActionRunning('run-verify')) {
          return sendJson(res, 200, { running: true });
        }
        const job = createJob('run-verify', config.stateDir);
        const child = spawn('powershell.exe', [
          '-NoProfile',
          '-ExecutionPolicy', 'Bypass',
          '-File', config.verifyScript,
          '-Roles', config.roles,
          '-OutDir', config.stateDir
        ], {
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe']
        });
        child.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.on('close', code => finishJob(job, config.stateDir, code));
        return sendJson(res, 200, { started: true, jobId: job.id });
      }

      case 'open-chrome': {
        const raw = body.port === undefined || body.port === null ? '' : String(body.port).trim();
        chromeScanCache = null;
        if (raw === '') {
          // main account Chrome (default profile, no debugging port)
          const scan = await scanChromes();
          let note = '';
          if (!scan.mainRunning) {
            setRestoreOnStartup(path.join(process.env.LOCALAPPDATA || '', 'Google', 'Chrome', 'User Data'));
          } else { note = '主 Chrome 已在執行，「繼續上次網頁」要關掉主 Chrome 後再按一次才會設定'; }
          spawn(config.chromeExe, [], { detached: true, stdio: 'ignore', windowsHide: false }).unref();
          return sendJson(res, 200, { started: true, main: true, note });
        }
        const targetPort = Number(raw);
        if (!Number.isInteger(targetPort) || targetPort < 1024 || targetPort > 65535) {
          return sendJson(res, 400, { error: 'Port 要是 1024～65535 的數字' });
        }
        if (await probeChrome(targetPort)) return sendJson(res, 200, { already: true });
        const userDataDir = path.join(config.chromeProfileRoot, String(targetPort));
        setRestoreOnStartup(userDataDir);
        spawn(config.chromeExe, [`--remote-debugging-port=${targetPort}`, `--user-data-dir=${userDataDir}`, '--no-first-run'], {
          detached: true, stdio: 'ignore', windowsHide: false
        }).unref();
        return sendJson(res, 200, { started: true, port: targetPort });
      }
      case 'gh-login': {
        if (isActionRunning('gh-login')) {
          return sendJson(res, 200, { running: true });
        }
        const job = createJob('gh-login', config.stateDir);

        const childEnv = { ...process.env, GH_BROWSER: 'cmd /c rem' };
        const child = spawn(config.ghExe, [
          'auth', 'login',
          '--hostname', 'github.com',
          '--git-protocol', 'https',
          '--web',
          '--skip-ssh-key'
        ], {
          env: childEnv,
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe']
        });

        let openedPage = false;
        async function ensureChromeAndOpenDevicePage() {
          if (openedPage) return;
          openedPage = true;
          const chromePort = config.githubChromePort;
          let running = await probeChrome(chromePort);
          if (!running) {
            const userDataDir = path.join(config.chromeProfileRoot, String(chromePort));
            const chromeProc = spawn(config.chromeExe, [
              `--remote-debugging-port=${chromePort}`,
              `--user-data-dir=${userDataDir}`,
              '--no-first-run'
            ], {
              detached: true,
              stdio: 'ignore',
              windowsHide: false
            });
            chromeProc.unref();
            for (let i = 0; i < 20; i++) {
              await new Promise(r => setTimeout(r, 500));
              if (await probeChrome(chromePort)) {
                running = true;
                break;
              }
            }
          }
          if (running) {
            try {
              await fetch(`http://127.0.0.1:${chromePort}/json/new?https://github.com/login/device`, {
                method: 'PUT'
              });
            } catch (err) {
              appendToConsoleJobLog(config.stateDir, `[gh-login] 開啟授權頁失敗: ${err.message}\n`);
            }
          }
        }

        function handleGhStream(chunk) {
          appendJobOutput(job, config.stateDir, chunk);
          const str = chunk.toString('utf8');
          // 抓取 one-time code (XXXX-XXXX)
          const match = str.match(/\b([A-Z0-9]{4}-[A-Z0-9]{4})\b/i);
          if (match) {
            ghLoginCode = match[1].toUpperCase();
            ensureChromeAndOpenDevicePage();
          }
        }

        child.stdout.on('data', handleGhStream);
        child.stderr.on('data', handleGhStream);

        child.on('close', (code) => {
          ghLoginCode = null;
          finishJob(job, config.stateDir, code);
          // 程序結束後再執行一次 ghExe auth setup-git
          const setupGit = spawn(config.ghExe, ['auth', 'setup-git'], {
            windowsHide: true,
            stdio: ['ignore', 'pipe', 'pipe']
          });
          setupGit.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
          setupGit.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
        });

        return sendJson(res, 200, { started: true, jobId: job.id });
      }

      case 'clone-repo': {
        const ghStatus = await checkGhAuth(config.ghExe);
        if (!ghStatus.loggedIn) {
          return sendJson(res, 409, { error: 'GitHub 尚未登入' });
        }
        if (fs.existsSync(path.join(config.repoDir, '.git'))) {
          return sendJson(res, 200, { already: true });
        }
        if (isActionRunning('clone-repo')) {
          return sendJson(res, 200, { running: true });
        }

        const job = createJob('clone-repo', config.stateDir);
        const child = spawn(config.gitExe, ['clone', config.repoUrl, config.repoDir], {
          windowsHide: true,
          stdio: ['ignore', 'pipe', 'pipe']
        });
        child.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
        child.on('close', code => {
          finishJob(job, config.stateDir, code);
          // after a successful clone, register the repo's daily auto-pull task (SOP 0-3)
          const task = path.join(config.repoDir, 'tools', 'install-auto-pull-task.ps1');
          if (code === 0 && fs.existsSync(task)) {
            const ap = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', task], { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
            ap.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
            ap.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
            // npm ci so tools that need playwright work right after the pull
            const npm = spawn('cmd.exe', ['/d', '/s', '/c', 'C:\\WORK\\TOOLS\\nodejs\\npm.cmd ci --no-audit --no-fund'], { cwd: config.repoDir, windowsHide: true, windowsVerbatimArguments: true, stdio: ['ignore', 'pipe', 'pipe'] });
            npm.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
            npm.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
          }
        });
        return sendJson(res, 200, { started: true, jobId: job.id });
      }

      case 'claude-login-seat1': {
        openVisible('Claude seat1 login - type /login', `& '${config.claudeExe}'`);
        return sendJson(res, 200, { started: true });
      }

      case 'claude-login-seat2': {
        openVisible('Claude seat2 login - type /login', `$env:CLAUDE_CONFIG_DIR='${config.claudeSeat2Dir}'; & '${config.claudeExe}'`);
        return sendJson(res, 200, { started: true });
      }

      case 'codex-login': {
        openVisible('Codex login', `& '${config.codexCmd}' login`);
        return sendJson(res, 200, { started: true });
      }

      case 'svn-continue': {
        // svnContinueCmd is a full command line from console.json (trusted config, not from the browser)
        const child = spawn('cmd.exe', ['/d', '/s', '/c', `start "SVN" ${config.svnContinueCmd}`], {
          detached: true, stdio: 'ignore', windowsHide: false, windowsVerbatimArguments: true
        });
        child.unref();
        return sendJson(res, 200, { started: true });
      }
      case 'install-app': {
        const target = (config.apps || []).find(a => a.id === body.app);
        if (!target) return sendJson(res, 400, { error: 'Invalid app' });
        if (await checkAppInstalled(target.id)) return sendJson(res, 200, { already: true });
        const wingetOk = await checkWingetAvailable();
        if (wingetOk && Array.isArray(target.winget)) {
          const jobName = 'install-app:' + target.id;
          if (isActionRunning(jobName)) return sendJson(res, 200, { running: true });
          const job = createJob(jobName, config.stateDir);
          const child = spawn('winget', target.winget, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
          child.stdout.on('data', d => appendJobOutput(job, config.stateDir, d));
          child.stderr.on('data', d => appendJobOutput(job, config.stateDir, d));
          child.on('close', code => { finishJob(job, config.stateDir, code); invalidateAppStatusCache(); });
          return sendJson(res, 200, { started: true, jobId: job.id });
        }
        spawn(config.chromeExe, [target.downloadUrl], { detached: true, stdio: 'ignore' }).unref();
        return sendJson(res, 200, { opened: target.downloadUrl });
      }

      case 'disable-cowork': {
        // system service setting: elevated (UAC once); owner clicks Yes
        const cmd = "Start-Process -FilePath '" + config.coworkDisableScript + "' -Verb RunAs";
        spawn('powershell.exe', ['-NoProfile', '-Command', cmd], { detached: true, stdio: 'ignore' }).unref();
        invalidateAppStatusCache();
        return sendJson(res, 200, { started: true });
      }

      case 'enable-devmode': {
        // open Settings > System > For developers; the owner flips the switch (Windows asks UAC itself)
        spawn('cmd.exe', ['/d', '/c', 'start', '', 'ms-settings:developers'], { detached: true, stdio: 'ignore' }).unref();
        invalidateAppStatusCache();
        return sendJson(res, 200, { started: true });
      }

      case 'open-app': {
        const target = (config.apps || []).find(a => a.id === body.app);
        if (!target) return sendJson(res, 400, { error: 'Invalid app' });
        if (target.launchExe) {
          const exe = expandEnv(target.launchExe);
          if (!fs.existsSync(exe)) return sendJson(res, 409, { error: '找不到程式：' + exe });
          spawn(exe, [], { detached: true, stdio: 'ignore' }).unref();
        } else if (target.appxName) {
          // MSIX app: start through shell:AppsFolder with its package family name and app id
          const ps = "$p = Get-AppxPackage -Name '" + target.appxName + "' | Select-Object -First 1; $id = (Get-AppxPackageManifest $p).Package.Applications.Application.Id | Select-Object -First 1; Start-Process ('shell:AppsFolder\\' + $p.PackageFamilyName + '!' + $id)";
          spawn('powershell.exe', ['-NoProfile', '-Command', ps], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
        } else {
          return sendJson(res, 400, { error: 'No launch method' });
        }
        return sendJson(res, 200, { started: true });
      }

      default:
        return sendJson(res, 400, { error: 'Invalid action' });
    }
  }

  // 其他路由回傳 404
  res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
  res.end('Not Found');
});

server.listen(serverPort, '127.0.0.1', () => {
  console.log(`console listening http://127.0.0.1:${serverPort}`);
});
