<script setup>
import { onMounted, onBeforeUnmount } from 'vue'
const props = defineProps({ title: String, wide: Boolean })
const emit = defineEmits(['close'])
function onKey(e) {
  if (e.key === 'Escape') emit('close')
}
onMounted(() => document.addEventListener('keydown', onKey))
onBeforeUnmount(() => document.removeEventListener('keydown', onKey))
</script>

<template>
  <Teleport to="body">
    <div class="modal-backdrop" @click.self="emit('close')">
      <div class="modal" :class="{ wide: props.wide }" role="dialog" aria-modal="true" :aria-label="title">
        <header class="modal-head">
          <h2>{{ title }}</h2>
          <button class="icon-btn" type="button" aria-label="Tutup" @click="emit('close')">✕</button>
        </header>
        <div class="modal-body"><slot /></div>
        <footer v-if="$slots.footer" class="modal-foot"><slot name="footer" /></footer>
      </div>
    </div>
  </Teleport>
</template>
