function load() {
    return require("./exporter");
}
const name = "x";
const dynamic = require(name);
load();
dynamic;
