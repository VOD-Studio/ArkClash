interface KeyedListItem {
  key: string;
}

export class KeyedListSource<T extends KeyedListItem> implements IDataSource {
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

  replace(items: T[], animate?: (apply: () => void) => void): void {
    const previous = this.items;
    if (this.listeners.length === 0) { this.items = items; return; }
    let prefix = 0;
    while (prefix < previous.length && prefix < items.length && previous[prefix].key === items[prefix].key) {
      ++prefix;
    }
    let suffix = 0;
    while (suffix < previous.length - prefix && suffix < items.length - prefix &&
      previous[previous.length - 1 - suffix].key === items[items.length - 1 - suffix].key) {
      suffix++;
    }
    const removed = previous.length - prefix - suffix;
    const added = items.length - prefix - suffix;
    if (removed > 0 && added > 0) {
      const apply = (): void => this.reconcile(previous, items);
      if (animate === undefined) { apply(); } else { animate(apply); }
      return;
    }
    if (removed > 0 || added > 0) {
      const operations: DataOperation[] = removed > 0 ?
        [{ type: DataOperationType.DELETE, index: prefix, count: removed }] :
        [{ type: DataOperationType.ADD, index: prefix, count: added }];
      const apply = (): void => this.publish(items, operations);
      if (animate === undefined) { apply(); } else { animate(apply); }
    }

    const changes: DataOperation[] = [];
    for (let index = 0; index < prefix; ++index) {
      if (previous[index] !== items[index]) { changes.push({ type: DataOperationType.CHANGE, index: index }); }
    }
    for (let offset = 1; offset <= suffix; ++offset) {
      const index = items.length - offset;
      if (previous[previous.length - offset] !== items[index]) {
        changes.push({ type: DataOperationType.CHANGE, index: index });
      }
    }
    this.publish(items, changes);
  }

  private publish(items: T[], operations: DataOperation[]): void {
    this.items = items;
    if (operations.length === 0) { return; }
    for (const listener of this.listeners) { listener.onDatasetChange(operations); }
  }

  private reconcile(previous: T[], items: T[]): void {
    const nextKeys = new Set<string>();
    for (const item of items) { nextKeys.add(item.key); }
    const retained: T[] = [];
    const positions = new Map<string, number>();
    const deletes: DataOperation[] = [];
    let deleted: number = 0;
    for (let index = 0; index < previous.length; ++index) {
      const row = previous[index];
      if (!nextKeys.has(row.key)) {
        ++deleted;
      } else {
        if (deleted > 0) { deletes.push({ type: DataOperationType.DELETE, index: index - deleted, count: deleted }); }
        deleted = 0;
        positions.set(row.key, retained.length);
        retained.push(row);
      }
    }
    if (deleted > 0) {
      deletes.push({ type: DataOperationType.DELETE, index: previous.length - deleted, count: deleted });
    }
    this.publish(retained, deletes);

    const order: number[] = [];
    const adds: DataOperation[] = [];
    let added: number = 0;
    for (const item of items) {
      const index = positions.get(item.key);
      if (index === undefined) {
        ++added;
      } else {
        if (added > 0) { adds.push({ type: DataOperationType.ADD, index: order.length, count: added }); }
        added = 0;
        order.push(index);
      }
    }
    if (added > 0) { adds.push({ type: DataOperationType.ADD, index: order.length, count: added }); }
    this.reorder(retained, order);

    const changes: DataOperation[] = [];
    let retainedIndex = 0;
    for (let index = 0; index < items.length; ++index) {
      const item = items[index];
      if (!positions.has(item.key)) { continue; }
      if (retained[retainedIndex] !== item) {
        changes.push({ type: DataOperationType.CHANGE, index: index });
      }
      ++retainedIndex;
    }
    this.publish(items, adds);
    this.publish(items, changes);
  }

  private reorder(rows: T[], order: number[]): void {
    const first: DataExchangeOperation[] = [];
    const second: DataExchangeOperation[] = [];
    for (let index = 0; index < order.length; ++index) {
      if (order[index] < 0 || order[index] === index) { continue; }
      const cycle: number[] = [];
      let next = index;
      do {
        cycle.push(next);
        const from = order[next];
        order[next] = -1;
        next = from;
      } while (next !== index);
      // 同一批不能操作同一个下标。每个置换环用两次不重叠的反转完成左移。
      this.reverseCycle(cycle, cycle.length - 1, first);
      this.reverseCycle(cycle, cycle.length - 2, second);
    }
    this.exchange(rows, first);
    this.exchange(rows, second);
  }

  private reverseCycle(cycle: number[], end: number, operations: DataExchangeOperation[]): void {
    for (let start = 0; start < end; ++start, --end) {
      operations.push({ type: DataOperationType.EXCHANGE, index: { start: cycle[start], end: cycle[end] } });
    }
  }

  private exchange(rows: T[], operations: DataExchangeOperation[]): void {
    for (const operation of operations) {
      const start = operation.index.start;
      const end = operation.index.end;
      const row = rows[start];
      rows[start] = rows[end];
      rows[end] = row;
    }
    this.publish(rows, operations);
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
