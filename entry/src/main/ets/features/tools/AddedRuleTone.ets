import { Tone } from '../../components/SheetParts';

/** 策略名的语义色：直连绿、拒绝红，其余跟随品牌色。 */
export function ruleTargetTone(target: string): Tone {
  if (target === 'DIRECT' || target === 'COMPATIBLE') { return 'success'; }
  if (target.startsWith('REJECT')) { return 'error'; }
  if (target === 'PASS' || target === 'PASS-RULE') { return 'neutral'; }
  return 'brand';
}
