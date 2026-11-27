<script setup>
// Tawaran aplikasi Android. banner = spanduk ringkas (dashboard di browser Android, bisa ditutup);
// selain itu kartu lengkap (Pengaturan & halaman /aplikasi).
import { onMounted } from 'vue'
import { apk, apkUrl, isAndroid, loadApk, dismissApkBanner } from '../androidApp'
import Icon from './Icon.vue'

defineProps({ banner: { type: Boolean, default: false } })
onMounted(loadApk)
</script>

<template>
  <div v-if="banner ? isAndroid && !apk.dismissed && apk.status === 'ready' : true" :class="banner ? 'apk-banner' : 'apk-card'">
    <template v-if="banner">
      <img src="/pwa-192.png" alt="" width="36" height="36" class="apk-icon" />
      <div class="grow apk-text">
        <b>Pasang aplikasi Android</b>
        <span class="small muted">Notifikasi dengan tombol Salin, Selesai & Tunda langsung dari notifikasi.</span>
      </div>
      <a class="btn primary sm" :href="apkUrl" download>Unduh</a>
      <button class="icon-btn" aria-label="Tutup tawaran aplikasi Android" @click="dismissApkBanner"><Icon name="x" :size="16" /></button>
    </template>
    <template v-else>
      <p class="muted small">
        Aplikasi Android AI Todo: notifikasi pengingat & kiriman dengan tombol <b>Salin</b>, <b>Selesai</b>, dan
        <b>Tunda</b> langsung dari notifikasi, plus Bagikan → AI Todo dari aplikasi lain.
      </p>
      <div class="row">
        <a v-if="apk.status === 'ready'" class="btn primary sm" :href="apkUrl" download>
          <Icon name="download" :size="14" /> Unduh APK{{ apk.version ? ` ${apk.version}` : '' }}
        </a>
        <span v-else-if="apk.status === 'loading' || apk.status === 'unknown'" class="small muted">Memeriksa rilis…</span>
        <span v-else class="tag">Belum tersedia di server ini</span>
      </div>
      <p v-if="apk.status === 'ready'" class="hint">
        <template v-if="isAndroid">Setelah terunduh, buka <b>AITodo.apk</b> → <b>Pasang</b>. Bila diminta, izinkan browser
          “memasang aplikasi tak dikenal”. Lalu masuk dengan alamat server, username & password yang sama.</template>
        <template v-else>Buka halaman ini di HP Android (Pengaturan → Aplikasi Android) untuk mengunduh & memasang langsung.</template>
      </p>
    </template>
  </div>
</template>

<style scoped>
.apk-banner {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 10px 6px 10px 12px;
  margin-bottom: 12px;
  border-radius: 12px;
  background: var(--accent-soft);
}
.apk-icon {
  border-radius: 8px;
  flex-shrink: 0;
}
.apk-text {
  display: flex;
  flex-direction: column;
  min-width: 0;
}
.apk-card .row {
  align-items: center;
}
.apk-card .btn {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  text-decoration: none;
}
.apk-banner .btn {
  text-decoration: none;
}
</style>
