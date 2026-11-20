import { taskpool } from '@kit.ArkTS';
import {
  appendCustomGroupFilter, customProfileSection, CustomProfileMutation, CustomProfileView, editCustomProfile,
  prepareCustomProfile
} from './CustomProfileYaml';

@Concurrent
function customProfileWork(source: string, mutation: string): CustomProfileView {
  return editCustomProfile(source, mutation === '' ? undefined : JSON.parse(mutation) as CustomProfileMutation);
}

@Concurrent
function customSectionWork(source: string, field: string): string {
  return customProfileSection(source, field);
}

@Concurrent
function customExportWork(source: string): string {
  return prepareCustomProfile(source);
}

@Concurrent
function customFilterWork(source: string, expression: string): string {
  return appendCustomGroupFilter(source, expression);
}

export async function inspectCustomProfile(source: string, mutation?: CustomProfileMutation): Promise<CustomProfileView> {
  return await taskpool.execute(customProfileWork, source, mutation === undefined ? '' : JSON.stringify(mutation)) as
    CustomProfileView;
}

export async function readCustomSection(source: string, field: string): Promise<string> {
  return await taskpool.execute(customSectionWork, source, field) as string;
}

export async function serializeCustomProfile(source: string): Promise<string> {
  return await taskpool.execute(customExportWork, source) as string;
}

export async function applyCustomGroupFilter(source: string, expression: string): Promise<string> {
  return await taskpool.execute(customFilterWork, source, expression) as string;
}
