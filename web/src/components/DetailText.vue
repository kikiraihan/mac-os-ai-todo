<script setup>
// Detail todo: teks polos dengan link http(s)/www yang bisa diklik, daftar "- x" tampil sebagai "• x".
// Tanpa v-html (CSP): teks dipecah jadi potongan teks & <a>.
import { computed } from 'vue'

const props = defineProps({ text: { type: String, default: '' } })
const URL_RE = /(https?:\/\/[^\s<>"']+|www\.[^\s<>"']+)/gi

const lines = computed(() =>
  props.text.split('\n').map((line) => {
    const bullet = /^\s*[-*]\s+/.test(line)
    const body = bullet ? line.replace(/^\s*[-*]\s+/, '') : line
    const parts = []
    let last = 0
    for (const m of body.matchAll(URL_RE)) {
      let url = m[0]
      const trail = url.match(/[.,;:!?)\]]+$/) // tanda baca di akhir kalimat bukan bagian link
      if (trail) url = url.slice(0, -trail[0].length)
      if (m.index > last) parts.push({ text: body.slice(last, m.index) })
      parts.push({ text: url, href: url.startsWith('www.') ? `https://${url}` : url })
      last = m.index + url.length
    }
    if (last < body.length) parts.push({ text: body.slice(last) })
    return { bullet, parts }
  }),
)
</script>

<template>
  <div class="detail-text">
    <div v-for="(l, i) in lines" :key="i" class="line" :class="{ bullet: l.bullet }">
      <template v-for="(p, j) in l.parts" :key="j">
        <a v-if="p.href" :href="p.href" target="_blank" rel="noopener noreferrer" @click.stop>{{ p.text }}</a>
        <template v-else>{{ p.text }}</template>
      </template>
      <template v-if="!l.parts.length">&nbsp;</template>
    </div>
  </div>
</template>

<style scoped>
.detail-text {
  line-height: 1.5;
  word-break: break-word;
}
.line.bullet {
  position: relative;
  padding-left: 1.1em;
}
.line.bullet::before {
  content: '•';
  position: absolute;
  left: 0.2em;
}
a {
  color: var(--accent);
}
</style>
