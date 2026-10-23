import { AbilityConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x0000;
const TAG: string = 'DshPocket';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'onCreate');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    windowStage.loadContent('pages/Index', (err: BusinessError) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, `loadContent failed: ${err.code} ${err.message}`);
        return;
      }
      this.paintSystemBars(windowStage);
    });
  }

  /**
   * 把状态栏 / 导航栏刷成和纸色背景一致。
   * 失败不影响使用，只是颜色不好看。
   */
  private paintSystemBars(windowStage: window.WindowStage): void {
    try {
      const mainWindow: window.Window = windowStage.getMainWindowSync();
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#F4EFE4',
        statusBarContentColor: '#17191D',
        navigationBarColor: '#F4EFE4',
        navigationBarContentColor: '#17191D'
      }).catch((error: BusinessError) => {
        hilog.warn(DOMAIN, TAG, `system bars failed: ${error.code}`);
      });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'system bars unavailable');
    }
  }
}
