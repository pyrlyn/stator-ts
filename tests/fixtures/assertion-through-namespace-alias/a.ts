import api from 'checks';

declare const s: string | undefined;
function viaOverloads() {
  api.ok(s !== undefined);
  s.length;
}
function viaSingle() {
  api.single(s !== undefined);
  s.length;
}
function viaGeneric() {
  api.equal(s, 'a');
  s.length;
}
function viaConst() {
  api.typed(s !== undefined);
  s.length;
}
function noEffect() {
  api.plain(s !== undefined);
  s.length;
}
