import * as dc from 'node:diagnostics_channel';
declare const t: dc.TracingChannel;
const a: dc.TracingChannelCollection = t;
const b: dc.TracingChannelCollection['start'] = t.start;
declare const t2: dc.TracingChannelCollection<unknown, object>;
const c: dc.TracingChannelCollection = t2;
