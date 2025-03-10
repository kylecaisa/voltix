const fs = require('fs');
const os = require('os');
const path = require('path');
const { Builder, By, until } = require('selenium-webdriver');
const chrome = require('selenium-webdriver/chrome');
const voltixService = require('./voltix');
const { tabReset } = require('./automationHelpers');
const log4js = require('log4js');
const axios = require('axios');
// 修改 run.js 添加以下参数
  
// 增强日志配置
log4js.configure({
  appenders: {
    console: { type: 'console' },
    file: { type: 'file', filename: 'app.log' }
  },
  categories: {
    default: { appenders: ['console', 'file'], level: 'debug' } // 开启debug级别
  }
});
const logger = log4js.getLogger('run');

// 增加全局配置
const CONFIG = {
  HEADLESS: true,  // 可改为false进行调试
  EXTENSION_LOAD_TIMEOUT: 30000,
  POLL_INTERVAL: 120000
};

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function killChromeProcesses() {
  try {
    await exec('pkill -f "chromium|chrome"');
    logger.debug('Killed existing Chrome processes');
  } catch (e) {
    logger.debug('No running Chrome processes found');
  }
}

async function createDriver() {
  //const profileDir = path.join(__dirname, 'profile');
  //if (!fs.existsSync(profileDir)) {
   // fs.mkdirSync(profileDir, { recursive: true });
  //}
  const profileDir = path.join(os.tmpdir(), `voltix-profile-${Date.now()}`);
  fs.mkdirSync(profileDir, { recursive: true });

  const options = new chrome.Options();
  options.addArguments(
    '--disable-blink-features=AutomationControlled',
    '--window-size=1200,800',
    '--force-device-scale-factor=0.8',
    '--lang=en-US'  // 强制英文环境避免本地化问题
  );

  // 扩展加载逻辑优化
  options.addExtensions(
    path.resolve(__dirname, "crxs", "voltix.crx"),
    path.resolve(__dirname, "crxs", "phantom.crx")
  );

  if (CONFIG.HEADLESS) {
    options.addArguments('--headless=new');  // 使用新版headless模式
  }
  
  if (os.platform() === 'linux') {
    options.addArguments('--no-sandbox', '--disable-dev-shm-usage');
    options.setChromeBinaryPath('/opt/chromium/chrome-linux/chrome');
  }

  const driver = await new Builder()
    .forBrowser('chrome')
    .setChromeOptions(options)
    .build();

  // 增加扩展初始化等待
  await sleep(CONFIG.EXTENSION_LOAD_TIMEOUT);
  await tabReset(driver);
  return driver;
}

async function reportServicePoint(account, service, point) {
  // ... 保持原有报告逻辑不变 ...
}

async function captureScreenshot(driver, prefix = 'error') {
  try {
    const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
    const filename = `${prefix}-${timestamp}.png`;
    const screenshot = await driver.takeScreenshot();
    fs.writeFileSync(filename, screenshot, 'base64');
    logger.debug(`Saved screenshot: ${filename}`);
  } catch (e) {
    logger.error('Failed to capture screenshot:', e.message);
  }
}

async function main() {
  let driver = null;
  let currentAccount = null;

  try {
    await killChromeProcesses(); 	
    const keys = await fs.promises.readFile('phantomKeys.txt', 'utf8')
      .then(data => data.split('\n').filter(l => l.trim()).slice(0, 1));

    if (keys.length === 0) {
      logger.error('No account found in phantomKeys.txt');
      return;
    }

    currentAccount = keys[0].trim();
    logger.info(`Initializing account: ${currentAccount}`);

    // 浏览器实例管理
    const initBrowser = async () => {
      if (driver) {
        try {
          await driver.quit();
        } catch (e) {
          logger.warn('Error during driver cleanup:', e.message);
        }
      }
      driver = await createDriver();
      logger.debug('New browser instance created');
    };

    await initBrowser();

    // 增强登录流程
    const performLogin = async () => {
      try {
        logger.debug('Starting wallet login sequence');
        await voltixService.login(driver, currentAccount.split(/\s+/));
        logger.info('Wallet initialized successfully');
        return true;
      } catch (e) {
        await captureScreenshot(driver, 'login-error');
        logger.error(`Wallet initialization FAILED: ${e.message}`);
        return false;
      }
    };

    if (!(await performLogin())) {
      await initBrowser();  // 立即尝试重启
      if (!(await performLogin())) {
        logger.error('Critical login failure after retry');
        return;
      }
    }

    // 增强监控循环
    while (true) {
      try {
        logger.debug('Checking points...');
        const points = await voltixService.check(driver);
        
        if (points !== false) {
          logger.info(`Current points: ${points}`);
          await reportServicePoint(
            { username: currentAccount }, 
            'voltix', 
            points
          );
        }
        
        await sleep(CONFIG.POLL_INTERVAL);
      } catch (e) {
        await captureScreenshot(driver, 'monitor-error');
        logger.error(`Monitoring error: ${e.message}`);

        // 分级恢复策略
        try {
          logger.info('Attempting soft recovery...');
          await driver.navigate().refresh();
          await sleep(10000);
          if (!(await performLogin())) {
            throw new Error('Soft recovery failed');
          }
        } catch (recoveryError) {
          logger.warn('Performing hard recovery...');
          await initBrowser();
          if (!(await performLogin())) {
            logger.error('Critical failure after hard recovery');
            break;
          }
        }
      }
    }
  } catch (error) {
    await captureScreenshot(driver, 'fatal-error');
    logger.error(`Fatal error: ${error.message}`);
  } finally {
    if (driver) {
      try {
        await driver.quit();
        logger.info('Browser instance cleaned up');
      } catch (e) {
        logger.warn('Error during final cleanup:', e.message);
      }
    }
  }
}

// 启动执行
main().catch(e => logger.error('Unhandled top-level error:', e));
