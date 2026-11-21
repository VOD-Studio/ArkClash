interface ArkStoreNative {
  run(request: string): Promise<string>;
}

declare const store: ArkStoreNative;
export default store;
