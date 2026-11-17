const store = require('./store')
module.exports = { warm() { store.load() } }