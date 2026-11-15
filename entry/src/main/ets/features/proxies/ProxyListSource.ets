interface ProxyListKey {
  key: string;
}

export class ProxyListSource<T extends ProxyListKey> implements IDataSource {
  private items: T[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): T {
    return this.items[index];
  }

  values(): T[] {
    return this.items;
  }

  replace(items: T[]): void {
    const previous = this.items;
    let prefix = 0;
    while (prefix < previous.length && prefix < items.length && previous[prefix].key === items[prefix].key) {
      prefix++;
    }
    let suffix = 0;
    while (suffix < previous.length - prefix && suffix < items.length - prefix &&
      previous[previous.length - 1 - suffix].key === items[items.length - 1 - suffix].key) {
      suffix++;
    }
    const removed = previous.length - prefix - suffix;
    const added = items.length - prefix - suffix;
    const operations: DataOperation[] = [];
    if (removed > 0 && added > 0) {
      operations.push({ type: DataOperationType.RELOAD });
    } else {
      if (removed > 0) {
        operations.push({ type: DataOperationType.DELETE, index: prefix, count: removed });
      } else if (added > 0) {
        operations.push({ type: DataOperationType.ADD, index: prefix, count: added });
      }
      for (let index = 0; index < prefix; index++) {
        if (previous[index] !== items[index]) {
          operations.push({ type: DataOperationType.CHANGE, index: index });
        }
      }
      for (let index = 0; index < suffix; index++) {
        const nextIndex = items.length - suffix + index;
        if (previous[previous.length - suffix + index] !== items[nextIndex]) {
          if (added > 0) {
            operations.splice(0, operations.length, { type: DataOperationType.RELOAD });
            break;
          }
          operations.push({ type: DataOperationType.CHANGE, index: previous.length - suffix + index });
        }
      }
    }
    this.items = items;
    if (operations.length > 0) {
      // 同一数据源只用批量协议；展开/收起须保留ADD/DELETE，不能退化成整表重载。
      for (const listener of this.listeners) {
        listener.onDatasetChange(operations);
      }
    }
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (!this.listeners.includes(listener)) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }
}
