Component({
  properties: { goods: Object },
  methods: {
    open() {
      wx.navigateTo({ url: `/packageGoods/detial/index?id=${this.data.goods.id}` })
    },
  },
})