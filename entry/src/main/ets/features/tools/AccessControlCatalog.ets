export type AccessAppCategory =
  'all' | 'browser' | 'container' | 'social' | 'finance' | 'shopping' | 'life' | 'media';

export const ACCESS_APP_CATEGORIES: AccessAppCategory[] = [
  'all', 'browser', 'container', 'social', 'finance', 'shopping', 'life', 'media'
];

export interface AccessCatalogEntry {
  bundleName: string;
  nameZh: string;
  nameEn: string;
  category: AccessAppCategory;
  keywords: string[];
  // 兼容容器类应用（如卓易通、出境易）无法细分内部单个安卓应用，界面需做明确提示。
  containerNote?: boolean;
  // 官方图标就位前，列表用品牌主色 + 首字的方块代替；鸿蒙不向三方应用开放读取其他应用的图标。
  iconColor: string;
}

/**
 * 内置常用鸿蒙原生应用目录。
 * HarmonyOS API 26 不向普通三方应用开放全量已安装应用列表，仅收录经核验的高频鸿蒙原生包名与兼容容器，
 * 其余应用通过手动输入或剪贴板批量导入补充。
 */
export const ACCESS_CONTROL_CATALOG: AccessCatalogEntry[] = [
  {
    bundleName: 'com.huawei.hmos.browser',
    nameZh: '华为浏览器',
    nameEn: 'Huawei Browser',
    category: 'browser',
    iconColor: '#0A59F7',
    keywords: ['browser', 'huawei', 'liulanqi', 'web']
  },
  {
    bundleName: 'com.droi.tong',
    nameZh: '卓易通',
    nameEn: 'Droitong',
    category: 'container',
    iconColor: '#2F7BF5',
    keywords: ['zhuoyitong', 'droitong', 'android', 'apk', 'rongqi'],
    containerNote: true
  },
  {
    bundleName: 'com.easy.hmos.abroad',
    nameZh: '出境易',
    nameEn: 'EasyAbroad',
    category: 'container',
    iconColor: '#12A67A',
    keywords: ['chujingyi', 'easyabroad', 'gms', 'google', 'overseas'],
    containerNote: true
  },
  {
    bundleName: 'com.tencent.wechat',
    nameZh: '微信',
    nameEn: 'WeChat',
    category: 'social',
    iconColor: '#07C160',
    keywords: ['weixin', 'wechat', 'wx', 'tencent']
  },
  {
    bundleName: 'com.tencent.mqq',
    nameZh: 'QQ',
    nameEn: 'QQ',
    category: 'social',
    iconColor: '#12B7F5',
    keywords: ['qq', 'mqq', 'tencent']
  },
  {
    bundleName: 'com.xingin.xhs_hos',
    nameZh: '小红书',
    nameEn: 'Xiaohongshu',
    category: 'social',
    iconColor: '#FF2442',
    keywords: ['xiaohongshu', 'xhs', 'rednote', 'red']
  },
  {
    bundleName: 'com.sina.weibo.stage',
    nameZh: '微博',
    nameEn: 'Weibo',
    category: 'social',
    iconColor: '#E6162D',
    keywords: ['weibo', 'sina', 'wb']
  },
  {
    bundleName: 'com.zhihu.hmos',
    nameZh: '知乎',
    nameEn: 'Zhihu',
    category: 'social',
    iconColor: '#0066FF',
    keywords: ['zhihu', 'zh']
  },
  {
    bundleName: 'com.alipay.mobile.client',
    nameZh: '支付宝',
    nameEn: 'Alipay',
    category: 'finance',
    iconColor: '#1677FF',
    keywords: ['zhifubao', 'alipay', 'zfb', 'pay']
  },
  {
    bundleName: 'com.taobao.taobao4hmos',
    nameZh: '淘宝',
    nameEn: 'Taobao',
    category: 'shopping',
    iconColor: '#FF5000',
    keywords: ['taobao', 'tb', 'alibaba']
  },
  {
    bundleName: 'com.jd.hm.mall',
    nameZh: '京东',
    nameEn: 'JD',
    category: 'shopping',
    iconColor: '#E1251B',
    keywords: ['jingdong', 'jd', 'mall']
  },
  {
    bundleName: 'com.sankuai.hmeituan',
    nameZh: '美团',
    nameEn: 'Meituan',
    category: 'life',
    iconColor: '#FFC300',
    keywords: ['meituan', 'mt', 'waimai']
  },
  {
    bundleName: 'com.amap.hmapp',
    nameZh: '高德地图',
    nameEn: 'Amap',
    category: 'life',
    iconColor: '#2B7BF6',
    keywords: ['gaode', 'amap', 'ditu', 'map']
  },
  {
    bundleName: 'com.ss.hm.ugc.aweme',
    nameZh: '抖音',
    nameEn: 'Douyin',
    category: 'media',
    iconColor: '#161823',
    keywords: ['douyin', 'dy', 'aweme', 'bytedance']
  },
  {
    bundleName: 'yylx.danmaku.bili',
    nameZh: '哔哩哔哩',
    nameEn: 'Bilibili',
    category: 'media',
    iconColor: '#FB7299',
    keywords: ['bilibili', 'bili', 'bzhan']
  }
];

export function findAccessCatalogEntry(bundleName: string): AccessCatalogEntry | undefined {
  return ACCESS_CONTROL_CATALOG.find((entry: AccessCatalogEntry): boolean => entry.bundleName === bundleName);
}
