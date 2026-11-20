import { GeneralPage } from '../features/tools/GeneralPage';
import { LogsPage } from '../features/tools/LogsPage';
import { common } from '@kit.AbilityKit';
import { accessibility } from '@kit.AccessibilityKit';
import { AppStorageV2, SymbolGlyphModifier } from '@kit.ArkUI';
import { HdsBarStyle, HdsTabs, HdsTabsBarChangeMode, HdsTabsController, HdsTabsFloatingStyle } from '@kit.UIDesignKit';
import { appUpdateState } from '../client/AppUpdate';
import { connection, Connection } from '../client/Connection';
import { traffic } from '../client/Traffic';
import { AppearanceState, appAppearance } from '../components/AppearanceState';
import { hdsGlass } from '../components/Theme';
import { ConnectionBar } from '../features/home/ConnectionBar';
import { ProfileItem, ProfileStore } from '../features/profiles/Profiles';
import { ProfilesPage } from '../features/profiles/ProfilesPage';
import { ProxiesPage } from '../features/proxies/ProxiesPage';
import { AboutPage } from '../features/tools/AboutPage';
import { AdvancedConfigPage } from '../features/tools/AdvancedConfigPage';
import { NetworkPage } from '../features/tools/NetworkPage';
import { ThemePage } from '../features/tools/ThemePage';
import { ToolRoute } from '../features/tools/ToolRoutes';
import { ToolsPage } from '../features/tools/ToolsPage';
import { ResourcesPage } from '../features/resources/ResourcesPage';
import { ConnectionsPage } from '../features/tools/ConnectionsPage';
import { DnsPage } from '../features/tools/DnsPage';
import { DnsOverridesPage } from '../features/tools/DnsOverridesPage';
import { ProfileExtensionPage } from '../features/profiles/ProfileExtensionPage';
import { ScriptEditorPage } from '../features/profiles/ScriptEditorPage';
import { LocalProxiesPage } from '../features/profiles/LocalProxiesPage';
import { ScriptsPage } from '../features/profiles/ScriptsPage';
import { AddedRulesPage } from '../features/tools/AddedRulesPage';
import { RuleSetsPage } from '../features/tools/RuleSetsPage';
import { ProxyFiltersPage } from '../features/tools/ProxyFiltersPage';
import { IconSetPreviewPage, IconSetsPage } from '../features/tools/IconSetsPage';
import { WindowInsets } from './WindowInsets';
import { DashboardTab } from './DashboardTab';

enum Tab {
  Home,
  Proxies,
  Profiles,
  Tools
}

function tabBar(icon: Resource, selectedIcon: Resource, label: Resource, accent: number,
  family: string): BottomTabBarStyle {
  return new BottomTabBarStyle({
    normal: new SymbolGlyphModifier(icon),
    selected: new SymbolGlyphModifier(selectedIcon).fontColor([accent])
  }, label).labelStyle({ selectedColor: accent, font: { family: family } });
}

interface IconSetRouteArgument {
  id: string;
}

interface ScriptRouteArgument { id: string; }

@Entry
@ComponentV2
struct Index {
  @Local private appStyle: AppearanceState = appAppearance;
  @Local private tabAlpha: number = 1;
  @Local stack: NavPathStack = new NavPathStack();
  @Local tab: number = Tab.Home;
  @Local foreground: boolean = true;
  @Local private mainVisible: boolean = true;
  @Local profiles: ProfileStore = new ProfileStore();
  @Local proxyPicker: boolean = false;
  @Local profilePicker: boolean = false;
  @Local homeEditing: boolean = false;
  @Local closeEditSignal: number = 0;
  @Local conn: Connection = connection;
  @Local insets: WindowInsets = AppStorageV2.connect(WindowInsets, () => new WindowInsets())!;
  @Local miniBarExpanded: boolean = false;
  @Local reduceMotion: boolean = true;
  private reductionListener: (enabled: boolean) => void = (enabled: boolean): void => {
    this.reduceMotion = enabled;
    if (enabled && this.tabAlpha !== 1) {
      this.getUIContext().animateTo({ duration: 0 }, () => { this.tabAlpha = 1; });
    }
  };
  private tabs: HdsTabsController = new HdsTabsController();
  private pickerScroller: ListScroller = new ListScroller();
  private profilePickerScroller: ListScroller = new ListScroller();
  // 每个页签一个 Scroller，绑定给 HdsTabs：页面滚动时页签栏收起、连接条展开。
  private scrollers: Scroller[] = [new Scroller(), new ListScroller(), new ListScroller(), new Scroller()];
  private context: common.UIAbilityContext = this.getUIContext().getHostContext() as common.UIAbilityContext;
  private warmRequested: boolean = false;

  aboutToAppear(): void {
    this.reduceMotion = accessibility.isAnimationReduceEnabledSync();
    accessibility.onAnimationReduceStateChange(this.reductionListener);
    this.profiles.load(this.context);
    this.conn.restore(this.context);
    this.conn.setDiagnosticsReceiverMounted(true);
    this.syncProfiles();
    this.scrollers.forEach((scroller: Scroller, index: number) => this.tabs.bindScroller(index, scroller));
  }

  aboutToDisappear(): void {
    this.conn.setDiagnosticsReceiverMounted(false);
    this.foreground = false;
    accessibility.offAnimationReduceStateChange(this.reductionListener);
    this.scrollers.forEach((scroller: Scroller) => this.tabs.unbindScroller(scroller));
    traffic.stop('shell');
    this.conn.observe(this.context, false);
    this.profiles.setForeground(false);
    appUpdateState.setForeground(this.context, false);
  }

  // 配置的更新由谁负责、要不要订阅 VPN 进程的推送，取决于连接状态和应用是否在前台（ADR-0009）。
  // @Monitor 不在初始化时触发，aboutToAppear 里先按缓存的状态调一次。
  @Monitor('conn.state', 'conn.hostState', 'conn.coreReady', 'foreground', 'profiles.loaded', 'profiles.loadError')
  syncProfiles(): void {
    this.conn.observe(this.context, this.foreground);
    if (!this.profiles.loaded) {
      return;
    }
    this.profiles.setCoreReady(this.conn.coreReady, this.conn.offlineWritable);
    // 交接：正在连接、正在断开时界面不发起新的更新。
    this.profiles.setForeground(this.foreground && !this.conn.busy);
    if (this.foreground && this.profiles.loadError === '' && !this.warmRequested) {
      this.warmRequested = true;
      this.conn.ensureReady(this.context, true).catch((): void => {});
    }
  }

  private activeProfile(): ProfileItem | undefined {
    return this.profiles.active();
  }


  // 流量推送只在有人看的时候订阅：首页可见，或者连接条展开着。
  @Monitor('tab', 'foreground', 'miniBarExpanded', 'conn.state')
  syncTraffic(): void {
    const watching = this.foreground && this.miniBarExpanded;
    if (watching && this.conn.connected) {
      traffic.start(this.context.filesDir, 'shell');
    } else {
      traffic.stop('shell');
    }
  }

  onPageShow(): void {
    this.foreground = true;
    appUpdateState.setForeground(this.context, true);
  }

  onPageHide(): void {
    this.warmRequested = false;
    this.foreground = false;
    appUpdateState.setForeground(this.context, false);
  }

  onBackPress(): boolean {
    if (this.profilePicker) {
      this.profilePicker = false;
      return true;
    }
    if (this.proxyPicker) {
      this.proxyPicker = false;
      return true;
    }
    if (this.tab === Tab.Home && this.homeEditing) {
      ++this.closeEditSignal;
      return true;
    }
    return false;
  }

  // 往下看内容时展开连接条、收起页签栏，往回滚时恢复。滚动不会自动触发，要应用自己调控制器。
  private onScrollDirection(down: boolean): void {
    if (this.appStyle.floating && down !== this.miniBarExpanded) {
      this.tabs.applyMiniBarStyle(down ? HdsBarStyle.EXPAND : HdsBarStyle.COLLAPSE);
    }
  }

  private topInset(): number {
    return this.getUIContext().px2vp(this.insets.top);
  }

  private floatingStyle(): HdsTabsFloatingStyle | undefined {
    if (!this.appStyle.floating) { return undefined; }
    return {
      // 悬浮页签保持原来的位置、系统材质及滚动迷你栏。
      barBottomMargin: 28,
      adaptToHandedness: true,
      systemMaterialEffect: hdsGlass(this.appStyle.glass),
      miniBar: {
        miniBarBuilder: () => this.MiniBar(),
        onBarStyleChange: (miniBarStyle: HdsBarStyle, _tabBarStyle: HdsBarStyle, _miniBarWidth: number,
          _tabBarWidth: number, _mode: HdsTabsBarChangeMode) => {
          this.miniBarExpanded = this.appStyle.floating && miniBarStyle === HdsBarStyle.EXPAND;
        }
      }
    };
  }

  private switchTab(index: number): void {
    if (index === this.tab) { return; }
    if (this.appStyle.motion === 'fade' && !this.reduceMotion) {
      const ui = this.getUIContext();
      ui.animateTo({ duration: 0 }, () => { this.tabAlpha = 0; this.tab = index; });
      ui.animateTo({ duration: 220, curve: Curve.EaseOut }, () => { this.tabAlpha = 1; });
    } else {
      this.tab = index;
    }
    if (index !== Tab.Home && this.homeEditing) { ++this.closeEditSignal; }
    this.onScrollDirection(false);
  }

  @Monitor('appStyle.floating')
  resetMiniBar(): void {
    this.miniBarExpanded = false;
  }

  private openProfileExtension(profile: string): void {
    const argumentsForPage: ScriptRouteArgument = { id: profile };
    this.stack.pushPath({ name: ToolRoute.ProfileExtension, param: argumentsForPage });
  }

  private openScriptEditor(id: string): void {
    const argumentsForPage: ScriptRouteArgument = { id: id };
    this.stack.pushPath({ name: ToolRoute.ScriptEditor, param: argumentsForPage });
  }

  private openIconSet(id: string): void {
    const argument: IconSetRouteArgument = { id: id };
    this.stack.pushPath({ name: ToolRoute.IconSetPreview, param: argument });
  }

  @Builder
  Routes(name: string, param: Object) {
    if (name === ToolRoute.Theme) {
      ThemePage({ reduceMotion: this.reduceMotion })
    } else if (name === ToolRoute.General) {
      GeneralPage()
    } else if (name === ToolRoute.Logs) {
      LogsPage({ foreground: this.foreground })
    } else if (name === ToolRoute.AdvancedConfig) {
      AdvancedConfigPage({ onOpen: (route: ToolRoute): void => { this.stack.pushPath({ name: route }); } })
    } else if (name === ToolRoute.Network) {
      NetworkPage({ foreground: this.foreground })
    } else if (name === ToolRoute.DnsOverrides) {
      DnsOverridesPage({ foreground: this.foreground, reduceMotion: this.reduceMotion })
    } else if (name === ToolRoute.AddedRules) {
      AddedRulesPage({ foreground: this.foreground, reduceMotion: this.reduceMotion })
    } else if (name === ToolRoute.LocalProxies) {
      LocalProxiesPage({ foreground: this.foreground })
    } else if (name === ToolRoute.RuleSets) {
      RuleSetsPage({ foreground: this.foreground })
    } else if (name === ToolRoute.ProxyFilters) {
      ProxyFiltersPage({ foreground: this.foreground })
    } else if (name === ToolRoute.IconSets) {
      IconSetsPage({ foreground: this.foreground, onPreview: (id: string): void => this.openIconSet(id) })
    } else if (name === ToolRoute.IconSetPreview) {
      IconSetPreviewPage({ setId: (param as IconSetRouteArgument).id })
    } else if (name === ToolRoute.Scripts) {
      ScriptsPage({ foreground: this.foreground, onEdit: (id: string): void => this.openScriptEditor(id) })
    } else if (name === ToolRoute.ScriptEditor) {
      ScriptEditorPage({ scriptId: (param as ScriptRouteArgument).id, foreground: this.foreground,
        onClose: (): void => { this.stack.pop(); } })
    } else if (name === ToolRoute.ProfileExtension) {
      ProfileExtensionPage({ profileId: (param as ScriptRouteArgument).id, currentProfile: this.profiles.current,
        foreground: this.foreground, onScripts: (): void => { this.stack.pushPath({ name: ToolRoute.Scripts }); },
        onStandardRules: (): void => { this.stack.pushPath({ name: ToolRoute.ProfileRules, param: param }); } })
    } else if (name === ToolRoute.ProfileRules) {
      AddedRulesPage({ profileId: (param as ScriptRouteArgument).id,
        foreground: this.foreground, reduceMotion: this.reduceMotion,
        onGlobalRules: (): void => { this.stack.pushPath({ name: ToolRoute.AddedRules }); } })
    } else if (name === ToolRoute.Resources) {
      ResourcesPage({ foreground: this.foreground, onScript: (id: string): void => this.openScriptEditor(id) })
    } else if (name === ToolRoute.Connections) {
      ConnectionsPage({ foreground: this.foreground })
    } else if (name === ToolRoute.Dns) {
      DnsPage({ foreground: this.foreground })
    } else if (name === ToolRoute.About) {
      AboutPage()
    }
  }

  build() {
    // 窗口是沉浸式布局（EntryAbility）：背景和 Tabs 铺满整个窗口，悬浮栏的 barBottomMargin（默认 28vp）
    // 从屏幕底边算起；各页签用 TabPage 让开状态栏，内容从标题栏下面滚过去。
    Stack() {
      this.Backdrop()
      Navigation(this.stack) {
        HdsTabs({ barPosition: BarPosition.End, controller: this.tabs, index: this.tab }) {
          TabContent() {
            DashboardTab({
              store: this.profiles, scroller: this.scrollers[Tab.Home], topInset: this.topInset(),
              visible: this.tab === Tab.Home && this.foreground && this.mainVisible, closeEditSignal: this.closeEditSignal,
              onScrollDirection: (down: boolean) => this.onScrollDirection(down),
              onEditingChanged: (editing: boolean) => { this.homeEditing = editing; },
              onSwitchProfile: (): void => { this.profilePicker = true; },
              onOpenProfiles: () => this.tabs.changeIndex(Tab.Profiles),
              onOpenProxies: () => { this.proxyPicker = true; },
              onOpenResources: (): void => { this.stack.pushPath({ name: ToolRoute.Resources }); }
            })
          }
          .tabBar(tabBar($r('sys.symbol.house'), $r('sys.symbol.house_fill'), $r('app.string.tab_home'),
            this.appStyle.palette.brand, this.appStyle.fontFamily))
          .opacity(this.tabAlpha)

          TabContent() {
            ProxiesPage({
              scroller: this.scrollers[Tab.Proxies],
              topInset: this.topInset(),
              visible: this.foreground && this.tab === Tab.Proxies,
              profileId: this.activeProfile()?.id ?? '',
              profileReady: this.profiles.ready,
              summary: this.profiles.summary,
              online: this.conn.coreReady,
              offlineWritable: this.conn.offlineWritable,
              onOpenProfiles: () => this.tabs.changeIndex(Tab.Profiles),
              onScrollDirection: (down: boolean) => this.onScrollDirection(down)
            })
          }
          .tabBar(tabBar($r('sys.symbol.paperplane'), $r('sys.symbol.paperplane_fill'), $r('app.string.tab_proxies'),
            this.appStyle.palette.brand, this.appStyle.fontFamily))
          .opacity(this.tabAlpha)

          TabContent() {
            ProfilesPage({
              scroller: this.scrollers[Tab.Profiles],
              onScrollDirection: (down: boolean) => this.onScrollDirection(down),
              store: this.profiles,
              topInset: this.topInset(),
              visible: this.foreground && this.tab === Tab.Profiles,
              onExtension: (profile: string): void => this.openProfileExtension(profile),
            })
          }
          .tabBar(tabBar($r('sys.symbol.doc_text'), $r('sys.symbol.doc_text_fill'), $r('app.string.tab_profiles'),
            this.appStyle.palette.brand, this.appStyle.fontFamily))
          .opacity(this.tabAlpha)

          TabContent() {
            ToolsPage({
              scroller: this.scrollers[Tab.Tools],
              onScrollDirection: (down: boolean) => this.onScrollDirection(down),
              topInset: this.topInset(),
              onOpen: (route: ToolRoute) => {
                this.stack.pushPath({ name: route });
              }
            })
          }
          .tabBar(tabBar($r('sys.symbol.square_grid_2x2'), $r('sys.symbol.square_grid_2x2'),
            $r('app.string.tab_tools'), this.appStyle.palette.brand, this.appStyle.fontFamily))
          .opacity(this.tabAlpha)
        }
        .scrollable(false)
        .animationDuration(this.reduceMotion || this.appStyle.motion === 'fade' ? 0 : 300)
        .barOverlap(this.appStyle.floating)
        .barBackgroundColor(this.appStyle.floating ? Color.Transparent : this.appStyle.palette.cardBackground)
        .vertical(false)
        .barFloatingStyle(this.floatingStyle())
        .onChange((index: number) => this.switchTab(index))
        // 不避让键盘：输入法弹出时页签栏留在键盘后面，不被顶到屏幕中间。
        .expandSafeArea([SafeAreaType.KEYBOARD])
        .height(LayoutPolicy.matchParent)
        .safeAreaPadding({ bottom: this.appStyle.floating ? 0 : this.getUIContext().px2vp(this.insets.bottom) })
        // 仅首页页签铺满窗口；原生子页的标题栏仍由 Navigation 避让系统区域。
        .ignoreLayoutSafeArea([LayoutSafeAreaType.SYSTEM], this.appStyle.floating ?
          [LayoutSafeAreaEdge.TOP, LayoutSafeAreaEdge.BOTTOM] : [LayoutSafeAreaEdge.TOP])
        .bindSheet($$this.profilePicker, this.ProfilePicker(), {
          title: { title: $r('app.string.tab_profiles') },
          height: SheetSize.LARGE,
          systemMaterial: this.appStyle.sheetMaterial(),
          showClose: true
        })
      }
      .expandSafeArea([SafeAreaType.KEYBOARD])
      .ignoreLayoutSafeArea([], [])
      .safeAreaPadding({ top: this.topInset() })
      .backgroundColor(Color.Transparent)
      .mode(NavigationMode.Stack)
      .hideTitleBar(true)
      .hideToolBar(true)
      .onNavBarStateChange((visible: boolean): void => { this.mainVisible = visible; })
      .navDestination(this.Routes)
    }
    .width('100%')
    .height('100%')
    .expandSafeArea([SafeAreaType.KEYBOARD])
    .bindSheet($$this.proxyPicker, this.ProxyPicker(), {
      title: { title: $r('app.string.tab_proxies') },
      detents: [SheetSize.LARGE],
      systemMaterial: this.appStyle.sheetMaterial(),
      showClose: true,
      onDisappear: () => { this.proxyPicker = false; }
    })
  }

  @Builder
  MiniBar() {
    ConnectionBar({
      expanded: this.miniBarExpanded,
      onOpen: () => this.tabs.changeIndex(Tab.Proxies)
    })
  }
  @Builder
  ProfilePicker() {
    ProfilesPage({
      store: this.profiles,
      scroller: this.profilePickerScroller,
      pickerMode: true,
      visible: this.foreground && this.profilePicker
    })
  }


  @Builder
  ProxyPicker() {
    ProxiesPage({
      scroller: this.pickerScroller,
      visible: this.foreground && this.proxyPicker,
      profileId: this.activeProfile()?.id ?? '',
      profileReady: this.profiles.ready,
      summary: this.profiles.summary,
      online: this.conn.coreReady,
      offlineWritable: this.conn.offlineWritable,
      pickerMode: true,
      onOpenProfiles: () => {
        this.proxyPicker = false;
        this.tabs.changeIndex(Tab.Profiles);
      }
    })
  }

  @Builder
  Backdrop() {
    Column()
      .width('100%')
      .height('100%')
      .backgroundColor(this.appStyle.palette.pageBackground)
  }
}
