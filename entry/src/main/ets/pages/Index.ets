import { common } from '@kit.AbilityKit';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsBarStyle, HdsTabs, HdsTabsBarChangeMode, HdsTabsController, hdsMaterial } from '@kit.UIDesignKit';
import { connection, Connection, ConnectionState } from '../client/Connection';
import { traffic } from '../client/Traffic';
import { ConnectionBar } from '../features/home/ConnectionBar';
import { HomePage } from '../features/home/HomePage';
import { ProfileStore } from '../features/profiles/Profiles';
import { ProfilesPage } from '../features/profiles/ProfilesPage';
import { ProxiesPage } from '../features/proxies/ProxiesPage';
import { ToolPage } from '../features/tools/ToolPages';
import { ToolRoute } from '../features/tools/ToolRoutes';
import { ToolsPage } from '../features/tools/ToolsPage';
import { WindowInsets } from './WindowInsets';

enum Tab {
  Home,
  Proxies,
  Profiles,
  Tools
}

function tabBar(icon: Resource, selectedIcon: Resource, label: Resource): BottomTabBarStyle {
  return new BottomTabBarStyle({
    normal: new SymbolGlyphModifier(icon),
    selected: new SymbolGlyphModifier(selectedIcon)
  }, label);
}

@Entry
@ComponentV2
struct Index {
  @Local stack: NavPathStack = new NavPathStack();
  @Local tab: number = Tab.Home;
  @Local foreground: boolean = true;
  @Local profiles: ProfileStore = new ProfileStore();
  @Local profileSheetRequested: boolean = false;
  @Local conn: Connection = connection;
  @Local insets: WindowInsets = AppStorageV2.connect(WindowInsets, () => new WindowInsets())!;
  @Local miniBarExpanded: boolean = false;
  private tabs: HdsTabsController = new HdsTabsController();
  // 每个页签一个 Scroller，绑定给 HdsTabs：页面滚动时页签栏收起、连接条展开。
  private scrollers: Scroller[] = [new Scroller(), new Scroller(), new Scroller(), new Scroller()];
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;

  aboutToAppear(): void {
    this.profiles.load(this.context);
    this.conn.restore(this.context);
    this.scrollers.forEach((scroller: Scroller, index: number) => this.tabs.bindScroller(index, scroller));
  }

  aboutToDisappear(): void {
    this.scrollers.forEach((scroller: Scroller) => this.tabs.unbindScroller(scroller));
    traffic.stop();
  }

  // 流量推送只在有人看的时候订阅：首页可见，或者连接条展开着。
  @Monitor('tab', 'foreground', 'miniBarExpanded', 'conn.state')
  syncTraffic(): void {
    const watching = this.foreground && (this.tab === Tab.Home || this.miniBarExpanded);
    if (watching && this.conn.connected) {
      traffic.start(this.context.filesDir);
    } else {
      traffic.stop();
    }
  }

  onPageShow(): void {
    this.foreground = true;
  }

  onPageHide(): void {
    this.foreground = false;
  }

  private topInset(): number {
    return this.getUIContext().px2vp(this.insets.top);
  }

  @Builder
  Routes(name: string) {
    ToolPage({ route: name })
  }

  build() {
    // 窗口是沉浸式布局（EntryAbility）：背景和 Tabs 铺满整个窗口，悬浮栏的 barBottomMargin（默认 28vp）
    // 从屏幕底边算起；各页签用 TabPage 让开状态栏，内容从标题栏下面滚过去。
    Stack() {
      this.Backdrop()
      Navigation(this.stack) {
        HdsTabs({ barPosition: BarPosition.End, controller: this.tabs }) {
          TabContent() {
            HomePage({
              scroller: this.scrollers[Tab.Home],
              topInset: this.topInset(),
              profileReady: this.profiles.ready,
              profileName: this.profiles.name,
              profileUpdatedAt: this.profiles.updatedAt,
              profileUpdating: this.profiles.downloading,
              usedBytes: (this.profiles.usage?.upload ?? 0) + (this.profiles.usage?.download ?? 0),
              totalBytes: this.profiles.usage?.total ?? 0,
              expireAt: this.profiles.usage?.expire ?? 0,
              visible: this.tab === Tab.Home && this.foreground,
              onAddProfile: () => {
                this.profileSheetRequested = true;
                this.tabs.changeIndex(Tab.Profiles);
              },
              onOpenProfiles: () => this.tabs.changeIndex(Tab.Profiles),
              onUpdateProfile: () => {
                this.profiles.download(this.profiles.url);
              },
              onOpenProxies: () => this.tabs.changeIndex(Tab.Proxies)
            })
          }
          .tabBar(tabBar($r('sys.symbol.house'), $r('sys.symbol.house_fill'), $r('app.string.tab_home')))

          TabContent() {
            ProxiesPage({ scroller: this.scrollers[Tab.Proxies], topInset: this.topInset() })
          }
          .tabBar(tabBar($r('sys.symbol.paperplane'), $r('sys.symbol.paperplane_fill'), $r('app.string.tab_proxies')))

          TabContent() {
            ProfilesPage({
              scroller: this.scrollers[Tab.Profiles],
              store: this.profiles,
              topInset: this.topInset(),
              sheetRequested: this.profileSheetRequested,
              onSheetHandled: () => {
                this.profileSheetRequested = false;
              }
            })
          }
          .tabBar(tabBar($r('sys.symbol.doc_text'), $r('sys.symbol.doc_text_fill'), $r('app.string.tab_profiles')))

          TabContent() {
            ToolsPage({
              scroller: this.scrollers[Tab.Tools],
              topInset: this.topInset(),
              onOpen: (route: ToolRoute) => {
                this.stack.pushPath({ name: route });
              }
            })
          }
          .tabBar(tabBar($r('sys.symbol.square_grid_2x2'), $r('sys.symbol.square_grid_2x2'),
            $r('app.string.tab_tools')))
        }
        .scrollable(false)
        // 有 BottomTabBarStyle 页签时切换动画默认是 0（没有动画），按其他样式的默认值给 300ms。
        .animationDuration(300)
        // 悬浮样式只在 barOverlap(true)、barPosition 为 End、横向页签时生效。
        .barOverlap(true)
        .vertical(false)
        .barFloatingStyle({
          // HdsTabs 默认贴底（0vp），官方示例和原生 Tabs 都是离屏幕底边 28vp，刚好在手势条上方。
          barBottomMargin: 28,
          adaptToHandedness: true,
          systemMaterialEffect: {
            materialType: hdsMaterial.MaterialType.IMMERSIVE,
            materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
          },
          miniBar: {
            miniBarBuilder: () => this.MiniBar(),
            onBarStyleChange: (miniBarStyle: HdsBarStyle, _tabBarStyle: HdsBarStyle, _miniBarWidth: number,
              _tabBarWidth: number, _mode: HdsTabsBarChangeMode) => {
              this.miniBarExpanded = miniBarStyle === HdsBarStyle.EXPAND;
            }
          }
        })
        .onChange((index: number) => {
          this.tab = index;
        })
        // 不避让键盘：输入法弹出时页签栏留在键盘后面，不被顶到屏幕中间。
        .expandSafeArea([SafeAreaType.KEYBOARD])
      }
      .expandSafeArea([SafeAreaType.KEYBOARD])
      // Navigation 默认让开状态栏和手势条；这里让内容铺满窗口，避让交给各页的标题栏和悬浮栏。
      .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM])
      .backgroundColor(Color.Transparent)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .hideToolBar(true)
      .navDestination(this.Routes)
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.KEYBOARD])
  }

  @Builder
  MiniBar() {
    ConnectionBar({
      expanded: this.miniBarExpanded,
      onOpen: () => this.tabs.changeIndex(Tab.Proxies)
    })
  }

  // 页面底色加一层顶部光晕；连接后光晕换成品牌色，用透明度交叉淡入。
  @Builder
  Backdrop() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.page_glow_idle'), 0], [$r('app.color.page_background'), 0.5]]
        })
      Column()
        .width('100%')
        .height('100%')
        .linearGradient({
          angle: 180,
          colors: [[$r('app.color.page_glow_connected'), 0], [$r('app.color.page_background'), 0.5]]
        })
        .opacity(this.conn.state === ConnectionState.Connected ? 1 : 0)
        .animation({ duration: 400, curve: Curve.EaseInOut })
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.page_background'))
  }
}
