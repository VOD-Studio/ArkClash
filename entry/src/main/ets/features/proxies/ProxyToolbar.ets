import { sheetMaterial } from '../../components/Theme';
import { ProxyBrowser } from './Proxies';
import { copyProxyStyle, ProxyDensity, ProxyIconStyle, ProxySort } from './ProxyLogic';
import { ProxyGroupJumpList } from './ProxyGroupJumpList';

@ComponentV2
export struct ProxyToolbar {
  @Param @Require browser: ProxyBrowser;
  @Param pickerMode: boolean = false;
  @Param active: boolean = true;
  @Event onOpenProfiles: () => void = () => {};
  @Event onLocate: (groupName: string) => void = () => {};
  @Local groupsShown: boolean = false;
  @Local popupWidth: number = 280;
  private densities: ProxyDensity[] = ['loose', 'standard', 'compact'];
  private sorts: ProxySort[] = ['none', 'name', 'delay'];
  private icons: ProxyIconStyle[] = ['filled', 'icon', 'hidden'];

  aboutToDisappear(): void {
    this.groupsShown = false;
  }

  @Monitor('active', 'pickerMode', 'browser.groups')
  closeUnavailableGroups(): void {
    if (!this.active || this.pickerMode || this.browser.groups.length === 0) {
      this.groupsShown = false;
    }
  }

  private toggleGroups(): void {
    if (this.active && this.browser.groups.length > 0) {
      this.groupsShown = !this.groupsShown;
    }
  }

  private chooseGroup(groupName: string): void {
    this.groupsShown = false;
    this.browser.setCurrentGroup(groupName);
    this.onLocate(groupName);
  }

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

  private toggleLayout(): void {
    const style = copyProxyStyle(this.browser.style);
    style.type = style.type === 'list' ? 'tab' : 'list';
    this.browser.changeStyle(style);
  }

  private toggleTimeout(): void {
    const style = copyProxyStyle(this.browser.style);
    style.hideTimeoutProxies = !style.hideTimeoutProxies;
    this.browser.changeStyle(style);
  }

  @Builder
  private styleMenu() {
    Menu() {
      MenuItemGroup({ header: $r('app.string.proxy_sort') }) {
        ForEach(this.sorts, (sort: ProxySort) => {
          MenuItem({ content: this.sortLabel(sort) })
            .selected(this.browser.style.sortType === sort)
            .selectIcon(true)
            .onClick(() => this.changeSort(sort))
        }, (sort: ProxySort): string => sort)
      }
      MenuItemGroup({ header: $r('app.string.proxy_layout_density') }) {
        ForEach(this.densities, (density: ProxyDensity) => {
          MenuItem({ content: this.densityLabel(density) })
            .selected(this.browser.style.layout === density)
            .selectIcon(true)
            .onClick(() => this.changeDensity(density, false))
        }, (density: ProxyDensity): string => density)
      }
      MenuItemGroup({ header: $r('app.string.proxy_card_density') }) {
        ForEach(this.densities, (cardDensity: ProxyDensity) => {
          MenuItem({ content: this.densityLabel(cardDensity) })
            .selected(this.browser.style.cardType === cardDensity)
            .selectIcon(true)
            .onClick(() => this.changeDensity(cardDensity, true))
        }, (cardDensity: ProxyDensity): string => cardDensity)
      }
      MenuItemGroup({ header: $r('app.string.proxy_group_icons') }) {
        ForEach(this.icons, (icon: ProxyIconStyle) => {
          MenuItem({ content: this.iconLabel(icon) })
            .selected(this.browser.style.iconStyle === icon)
            .selectIcon(true)
            .onClick(() => this.changeIcon(icon))
        }, (icon: ProxyIconStyle): string => icon)
      }
      MenuItem({ content: $r('app.string.proxy_hide_timeout') })
        .selected(this.browser.style.hideTimeoutProxies)
        .selectIcon(true)
        .onClick(() => this.toggleTimeout())
      MenuItem({ content: $r('app.string.proxy_open_profiles') })
        .onClick(() => this.onOpenProfiles())
    }
  }

  @Builder
  private groupChoices() {
    ProxyGroupJumpList({
      browser: this.browser,
      active: this.active && this.groupsShown,
      onChoose: (groupName: string) => this.chooseGroup(groupName)
    })
  }

  build() {
    Column({ space: 8 }) {
      Row({ space: 8 }) {
        TextInput({ text: this.browser.query, placeholder: $r('app.string.proxy_search') })
          .layoutWeight(1)
          .height(44)
          .fontSize(14)
          .backgroundColor($r('app.color.card_background'))
          .enterKeyType(EnterKeyType.Search)
          .onChange((query: string) => this.browser.setQuery(query))
        if (this.browser.query !== '') {
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.xmark'))
              .fontSize(16)
              .fontColor([$r('sys.color.font_secondary')])
          }
          .width(44)
          .height(44)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.proxy_clear_search'))
          .onClick(() => this.browser.setQuery(''))
        }
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.arrow_clockwise'))
            .fontSize(18)
            .fontColor([$r('app.color.brand')])
        }
        .width(44)
        .height(44)
        .backgroundColor(Color.Transparent)
        .accessibilityText($r('app.string.proxy_refresh'))
        .enabled(!this.browser.loading)
        .onClick(() => this.browser.refresh())
      }
      .width('100%')
      if (!this.pickerMode) {
        Row({ space: 8 }) {
          Button(this.browser.style.type === 'list' ? $r('app.string.proxy_view_list') : $r('app.string.proxy_view_tab'))
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .backgroundColor($r('app.color.brand_soft'))
            .height(36)
            .onClick(() => this.toggleLayout())
          Button($r('app.string.proxy_jump_group'))
            .fontSize(12)
            .fontColor($r('app.color.brand'))
            .backgroundColor(Color.Transparent)
            .height(36)
            .enabled(this.active && this.browser.groups.length > 0)
            .onClick(() => this.toggleGroups())
            .bindPopup(this.groupsShown, {
              builder: this.groupChoices,
              placement: Placement.BottomLeft,
              enableArrow: false,
              autoCancel: true,
              focusable: true,
              mask: true,
              targetSpace: 8,
              width: this.popupWidth,
              radius: 16,
              popupColor: $r('app.color.card_background'),
              systemMaterial: sheetMaterial(),
              onStateChange: (event: PopupStateChangeParam): void => {
                if (!event.isVisible) {
                  this.groupsShown = false;
                }
              }
            })
          Blank()
          Button({ type: ButtonType.Circle }) {
            SymbolGlyph($r('sys.symbol.slider_horizontal_2'))
              .fontSize(18)
              .fontColor([$r('app.color.brand')])
          }
          .width(44)
          .height(36)
          .backgroundColor(Color.Transparent)
          .accessibilityText($r('app.string.proxy_style'))
          .bindMenu(this.styleMenu)
        }
        .width('100%')
      }
    }
    .width('100%')
    .onSizeChange((_before: SizeOptions, after: SizeOptions): void => {
      const available = Number(after.width);
      if (available > 0) {
        this.popupWidth = Math.min(280, available);
      }
    })
  }
}
