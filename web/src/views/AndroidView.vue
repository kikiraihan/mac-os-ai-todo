<script setup>
// Halaman tujuan setelah masuk dari tautan unduh APK (/unduh/AITodo.apk tanpa login → /masuk?next=/aplikasi).
import AndroidAppCard from '../components/AndroidAppCard.vue'
</script>

<template>
  <div class="page">
    <div class="page-head"><h1>Aplikasi Android</h1></div>
    <section class="card"><AndroidAppCard /></section>
  </div>
</template>
