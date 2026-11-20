import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { detectBarcode, scanBarcode, scanCore } from '@kit.ScanKit';
import { validSubscriptionUrl } from '../shared/profiles/Download';
import { ProfileError } from '../shared/profiles/Errors';
import { installConfigSource } from '../shared/profiles/InstallConfig';
import { isProxyShareLink } from '../shared/profiles/ShareProfile';

function sourceFromResults(results: scanBarcode.ScanResult[]): string {
  for (const result of results) {
    const source = result.originalValue.trim();
    if (validSubscriptionUrl(source) || isProxyShareLink(source)) { return source; }
    const install = installConfigSource(source);
    if (install !== undefined) { return install; }
  }
  throw new ProfileError('qr_invalid');
}

export async function scanProfileQr(context: common.UIAbilityContext): Promise<string | undefined> {
  let result: scanBarcode.ScanResult;
  try {
    if (!scanCore.isDefaultScanSupported()) { throw new Error('unsupported'); }
    result = await scanBarcode.startScanForResult(context, { scanTypes: [scanCore.ScanType.QR_CODE], enableAlbum: true });
  } catch (error) {
    if ((error as BusinessError).code === 1000500002) { return undefined; }
    throw new ProfileError('qr_camera');
  }
  return sourceFromResults([result]);
}

export async function readProfileQrPhoto(): Promise<string | undefined> {
  let results: scanBarcode.ScanResult[];
  try {
    const options = new photoAccessHelper.PhotoSelectOptions();
    options.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    options.maxSelectNumber = 1;
    const selection = await new photoAccessHelper.PhotoViewPicker().select(options);
    const uri = selection.photoUris[0];
    if (uri === undefined) { return undefined; }
    results = await detectBarcode.decode({ uri: uri }, { scanTypes: [scanCore.ScanType.QR_CODE] });
  } catch (error) { throw new ProfileError('qr_photo'); }
  return sourceFromResults(results);
}
