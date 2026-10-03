<script setup lang="ts">
import { onMounted, onUnmounted, ref, watch } from "vue";

const svg = ref<string | null>(null);

function onClick(event: MouseEvent) {
	const target = event.target as Element | null;
	const diagram = target?.closest(".mermaid svg");
	if (!diagram || target?.closest(".mermaid-zoom")) return;
	// Give the copy unique IDs so that Mermaid doesn't render into it.
	svg.value = diagram.outerHTML.replaceAll(diagram.id, `${diagram.id}-zoom`);
}

function onKeydown(event: KeyboardEvent) {
	if (event.key === "Escape") svg.value = null;
}

watch(svg, (value) => {
	document.body.style.overflow = value ? "hidden" : "";
});

onMounted(() => {
	document.addEventListener("click", onClick);
	document.addEventListener("keydown", onKeydown);
});

onUnmounted(() => {
	document.removeEventListener("click", onClick);
	document.removeEventListener("keydown", onKeydown);
	document.body.style.overflow = "";
});
</script>

<template>
	<Teleport to="body">
		<div
			v-if="svg"
			class="mermaid-zoom"
			role="dialog"
			aria-modal="true"
			aria-label="Enlarged diagram"
			@click="svg = null"
			v-html="svg"
		/>
	</Teleport>
</template>

<style>
.mermaid svg {
	cursor: zoom-in;
}

.mermaid-zoom {
	position: fixed;
	inset: 0;
	z-index: 1000;
	display: flex;
	align-items: center;
	justify-content: center;
	padding: 32px;
	background: var(--vp-c-bg);
	cursor: zoom-out;
}

.mermaid-zoom svg {
	width: 100%;
	height: 100%;
	max-width: none !important;
}
</style>
