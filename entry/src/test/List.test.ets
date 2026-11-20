import { describe, it } from '@ohos/hypium';
import { verifyConfigInputContract, verifySettingsContract } from './ContractCases';
import { contractFixtures } from './ContractFixtures';

export default function testsuite(): void {
  describe('ControllerContract', (): void => {
    it('settings', 0, (): void => {
      verifySettingsContract(contractFixtures);
    });
    it('configInput', 0, (): void => {
      verifyConfigInputContract(contractFixtures);
    });
  });
}
