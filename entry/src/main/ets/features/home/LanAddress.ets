import { connection } from '@kit.NetworkKit';

const FAMILY_IPV4 = 1;

export async function lanAddress(): Promise<string> {
  let cellular = '';
  const networks = await connection.getAllNets();
  for (const network of networks) {
    const bearers = (await connection.getNetCapabilities(network)).bearerTypes;
    if (bearers.includes(connection.NetBearType.BEARER_VPN)) {
      continue;
    }
    const properties = await connection.getConnectionProperties(network);
    const ipv4 = properties.linkAddresses.find((address: connection.LinkAddress): boolean =>
      address.address.family === FAMILY_IPV4);
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
  return cellular;
}
