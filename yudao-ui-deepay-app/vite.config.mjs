import { defineConfig } from 'vite'
import uni from '@dcloudio/vite-plugin-uni'
import Components from '@uni-helper/vite-plugin-uni-components'
import { WotResolver } from 'wot-design-uni/resolver'
import AutoImport from 'unplugin-auto-import/vite'

export default defineConfig({
  plugins: [
    uni(),
    Components({
      resolvers: [WotResolver()],
      dts: false,
    }),
    AutoImport({
      imports: ['vue', 'uni-app'],
      dts: false,
    }),
  ],
})
