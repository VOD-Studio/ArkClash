const APP_GLYPHS: Record<string, Resource> = {
  'search': $r('sys.symbol.magnifyingglass'),
  'more': $r('sys.symbol.ellipsis_circle'),
  'bolt': $r('sys.symbol.bolt'),
  'locate': $r('sys.symbol.scope'),
  'chevronDown': $r('sys.symbol.chevron_down'),
  'chevronUp': $r('sys.symbol.chevron_up'),
  'close': $r('sys.symbol.xmark'),
  'pin': $r('sys.symbol.pin'),
  'check': $r('sys.symbol.checkmark'),
  'clock': $r('sys.symbol.clock'),
  'appsList': $r('sys.symbol.list_bullet'),
  'sort': $r('sys.symbol.sort'),
  'dashboard': $r('sys.symbol.square_grid_2x2'),
  'textSize': $r('sys.symbol.textformat'),
  'iconTile': $r('sys.symbol.picture'),
  'eyeOff': $r('sys.symbol.eye_slash'),
  'edit': $r('sys.symbol.pencil_line'),
  'proxies': $r('sys.symbol.paperplane'),
  'profiles': $r('sys.symbol.doc_text'),
  'tools': $r('sys.symbol.wrench_and_screwdriver'),
  'connections': $r('sys.symbol.connection'),
  'target': $r('sys.symbol.scope'),
  'arrowUp': $r('sys.symbol.arrow_up'),
  'arrowDown': $r('sys.symbol.arrow_down'),
  'sync': $r('sys.symbol.arrow_2_circlepath'),
  'add': $r('sys.symbol.plus'),
  'remove': $r('sys.symbol.minus'),
  'rules': $r('sys.symbol.list_bullet'),
  'layers': $r('sys.symbol.layer'),
  'status': $r('sys.symbol.waveform_path_ecg_square'),
  'verified': $r('sys.symbol.checkmark_shield'),
  'swap': $r('sys.symbol.arrow_left_arrow_right'),
  'split': $r('sys.symbol.route'),
  'speed': $r('sys.symbol.gauge_with_dots_needle_33percent'),
  'memory': $r('sys.symbol.memory_module'),
  'devices': $r('sys.symbol.nearby_devices'),
  'vpn': $r('sys.symbol.key_shield'),
  'wifi': $r('sys.symbol.wifi'),
  'copy': $r('sys.symbol.rectangle_on_rectangle'),
  'chevronForward': $r('sys.symbol.chevron_right'),
  'play': $r('sys.symbol.play'),
  'pause': $r('sys.symbol.pause')
};

@ComponentV2
export struct AppGlyph {
  @Param name: string = 'search';
  @Param iconSize: number = 24;
  @Param iconColor: ResourceColor = $r('sys.color.icon_primary');

  build() {
    SymbolGlyph(APP_GLYPHS[this.name])
      .fontSize(this.iconSize)
      .fontColor([this.iconColor])
      .width(this.iconSize)
      .height(this.iconSize)
      .hitTestBehavior(HitTestMode.None)
  }
}
