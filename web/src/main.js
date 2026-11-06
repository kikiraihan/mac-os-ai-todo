import { createApp } from 'vue'
import App from './App.vue'
import router from './router'
import './style.css'
import { installPickers } from './pickers'
import { initUpdates } from './update'

installPickers()
initUpdates()

createApp(App).use(router).mount('#app')
