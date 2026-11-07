import { connection } from '@kit.NetworkKit';

// NetAddress.family：1 = IPv4。
const FAMILY_IPV4 = 1;

/**
 * 本机在局域网里的 IPv4 地址，优先 Wi-Fi，其次蜂窝；查不到返回空串。
 * 连着 VPN 时默认网络是 VPN 自己（TUN 的地址），所以按承载类型挑，跳过 VPN。
 */
export function lanAddress(): string {
  let cellular = '';
  try {
    for (const net of connection.getAllNetsSync()) {
      const bearers = connection.getNetCapabilitiesSync(net).bearerTypes;
      if (bearers.includes(connection.NetBearType.BEARER_VPN)) {
        continue;
      }
      const ipv4 = connection.getConnectionPropertiesSync(net).linkAddresses
        .find((a: connection.LinkAddress) => a.address.family === FAMILY_IPV4);
      if (ipv4 === undefined) {
        continue;
      }
      if (bearers.includes(connection.NetBearType.BEARER_WIFI)) {
        return ipv4.address.address;
      }
      if (cellular === '' && bearers.includes(connection.NetBearType.BEARER_CELLULAR)) {
        cellular = ipv4.address.address;
      }
    }
  } catch (e) {
    return '';
  }
  return cellular;
}
