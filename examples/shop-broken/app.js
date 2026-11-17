const { request } = require('./utils/request')
const cache = require('./utils/cache')

App({
  onLaunch() {
    request('/session')
    cache.warm()
  },
})