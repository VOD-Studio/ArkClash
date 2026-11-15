import { SymbolGlyphModifier } from '@kit.ArkUI';
import { AppGlyph } from '../../components/AppGlyph';
import { HEADER_ACTION } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { copyProxyStyle, ProxyDensity, ProxyIconStyle, ProxySort } from './ProxyLogic';

@ComponentV2
export struct ProxyToolbar {
  @Param @Require browser: ProxyBrowser;
  @Param pickerMode: boolean = false;
  @Param active: boolean = true;
  @Param motionEnabled: boolean = false;
  @Local searchShown: boolean = false;
  private densities: ProxyDensity[] = ['loose', 'standard', 'compact'];
  private sorts: ProxySort[] = ['none', 'delay', 'name'];
  private icons: ProxyIconStyle[] = ['filled', 'icon', 'hidden'];

  private densityLabel(density: ProxyDensity): ResourceStr {
    switch (density) {
      case 'loose': return $r('app.string.proxy_density_loose');
      case 'compact': return $r('app.string.proxy_density_compact');
      default: return $r('app.string.proxy_density_standard');
    }
  }

  private sortLabel(sort: ProxySort): ResourceStr {
    switch (sort) {
      case 'name': return $r('app.string.proxy_sort_name');
      case 'delay': return $r('app.string.proxy_sort_delay');
      default: return $r('app.string.proxy_sort_none');
    }
  }

  private iconLabel(style: ProxyIconStyle): ResourceStr {
    switch (style) {
      case 'filled': return $r('app.string.proxy_icon_filled');
      case 'icon': return $r('app.string.proxy_icon_only');
      default: return $r('app.string.proxy_icon_hidden');
    }
  }

  private changeDensity(density: ProxyDensity, card: boolean): void {
    const style = copyProxyStyle(this.browser.style);
    if (card) {
      style.cardType = density;
    } else {
      style.layout = density;
    }
    this.browser.changeStyle(style);
  }

  private changeSort(sort: ProxySort): void {
    const style = copyProxyStyle(this.browser.style);
    style.sortType = sort;
    this.browser.changeStyle(style);
  }

  private changeIcon(icon: ProxyIconStyle): void {
    const style = copyProxyStyle(this.browser.style);
    style.iconStyle = icon;
    this.browser.changeStyle(style);
  }

  private toggleTimeout(): void {
    const style = copyProxyStyle(this.browser.style);
    style.hideTimeoutProxies = !style.hideTimeoutProxies;
    this.browser.changeStyle(style);
  }

  private closeSearch(): void {
    this.browser.setQuery('');
    this.searchShown = false;
  }

  @Builder
  private sortMenu() {
    Menu() {
      ForEach(this.sorts, (sort: ProxySort) => {
        MenuItem({ content: this.sortLabel(sort) })
          .selected(this.browser.style.sortType === sort)
          .selectIcon(true)
          .onClick(() => this.changeSort(sort))
      }, (sort: ProxySort): string => sort)
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  @Builder
  private gridMenu() {
    Menu() {
      ForEach(this.densities, (density: ProxyDensity) => {
        MenuItem({ content: density === 'compact' ? $r('app.string.proxy_layout_tight') : this.densityLabel(density) })
          .selected(this.browser.style.layout === density)
          .selectIcon(true)
          .onClick(() => this.changeDensity(density, false))
      }, (density: ProxyDensity): string => density)
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  @Builder
  private cardMenu() {
    Menu() {
      ForEach(this.densities, (density: ProxyDensity) => {
        MenuItem({ content: this.densityLabel(density) })
          .selected(this.browser.style.cardType === density)
          .selectIcon(true)
          .onClick(() => this.changeDensity(density, true))
      }, (density: ProxyDensity): string => density)
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  @Builder
  private iconMenu() {
    Menu() {
      ForEach(this.icons, (icon: ProxyIconStyle) => {
        MenuItem({ content: this.iconLabel(icon) })
          .selected(this.browser.style.iconStyle === icon)
          .selectIcon(true)
          .onClick(() => this.changeIcon(icon))
      }, (icon: ProxyIconStyle): string => icon)
    }
    .font({ size: 15, weight: FontWeight.Normal })
  }

  @Builder
  private styleMenu() {
    Menu() {
      if ((this.browser.groups[this.browser.groupIndex]?.pinned ?? '') !== '') {
        MenuItem({ content: $r('app.string.proxy_clear_pin') })
          .enabled(this.active && (this.browser.online || this.browser.offlineWritable))
          .onClick(() => this.browser.clearPin(this.browser.currentGroup))
      }
      MenuItem({ content: $r('app.string.proxy_sort'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.sort')), builder: this.sortMenu })
      MenuItem({
        content: $r('app.string.proxy_menu_layout'),
        symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.square_grid_2x2')),
        builder: this.gridMenu
      })
      MenuItem({ content: $r('app.string.proxy_menu_size'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.textformat')), builder: this.cardMenu })
      MenuItem({ content: $r('app.string.proxy_menu_icon_style'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.picture')), builder: this.iconMenu })
      MenuItem({ content: $r('app.string.proxy_hide_timeout'), symbolStartIcon: new SymbolGlyphModifier($r('sys.symbol.eye_slash')) })
        .selected(this.browser.style.hideTimeoutProxies)
        .selectIcon(true)
        .onClick(() => this.toggleTimeout())
    }
    .font({ size: 15, weight: FontWeight.Normal })
    .subMenuExpandingMode(SubMenuExpandingMode.STACK_EXPAND)
  }

  @Builder
  private testAction() {
    Button({ type: ButtonType.Circle }) {
      if (this.browser.groups[this.browser.groupIndex]?.testing === true && this.active) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color($r('sys.color.font_primary'))
          .enableLoading(this.active)
      } else {
        AppGlyph({ name: 'bolt', iconSize: 24 })
      }
    }
    .attributeModifier(HEADER_ACTION)
    .accessibilityText($r('app.string.proxy_test_current_group'))
    .enabled(this.active && this.browser.online && !(this.browser.groups[this.browser.groupIndex]?.testing ?? false))
    .onClick(() => this.browser.test(this.browser.currentGroup))
  }

  build() {
    Row({ space: 8 }) {
      if (this.searchShown || this.pickerMode) {
        TextInput({ text: this.browser.query, placeholder: $r('app.string.proxy_search') })
          .layoutWeight(1)
          .height(44)
          .fontSize(17)
          .backgroundColor($r('app.color.card_background'))
          .borderRadius(22)
          .enterKeyType(EnterKeyType.Search)
          .onChange((query: string) => this.browser.setQuery(query))
        if (this.pickerMode) {
          this.testAction()
        }
        if (!this.pickerMode) {
          Button({ type: ButtonType.Circle }) {
            AppGlyph({ name: 'close', iconSize: 24 })
          }
          .attributeModifier(HEADER_ACTION)
          .accessibilityText($r('app.string.proxy_search_close'))
          .onClick(() => this.closeSearch())
        }
      } else {
        Text($r('app.string.tab_proxies'))
          .fontSize(24)
          .lineHeight(30)
          .fontWeight(600)
          .fontColor($r('sys.color.font_primary'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Row({ space: 8 }) {
          Button({ type: ButtonType.Circle }) {
            AppGlyph({ name: 'search', iconSize: 24 })
          }
          .attributeModifier(HEADER_ACTION)
          .accessibilityText($r('app.string.proxy_search'))
          .onClick(() => { this.searchShown = true; })
        }
        Button({ type: ButtonType.Circle }) {
          AppGlyph({ name: 'more', iconSize: 24 })
        }
        .attributeModifier(HEADER_ACTION)
        .accessibilityText($r('app.string.proxy_style'))
        .bindMenu(this.styleMenu, {
          placement: Placement.BottomRight,
          transition: this.motionEnabled ? undefined : TransitionEffect.IDENTITY
        })
      }
    }
    .width('100%')
    .height(this.pickerMode ? 56 : 72)
    .padding({ left: 16, right: 16 })
  }
}
