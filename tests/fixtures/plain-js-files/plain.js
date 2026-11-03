// Unchecked JavaScript keeps only binder and grammar errors.
function f(a) {
    return a.missing;
}
let twice = 1;
let twice = 2;
f(1);
