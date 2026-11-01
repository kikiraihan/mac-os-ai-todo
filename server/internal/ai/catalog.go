package ai

// Builtin adalah isi awal katalog model. Hanya titik awal: daftar model gratis
// berubah dari waktu ke waktu, jadi admin mengelolanya dari halaman Admin →
// Model AI (tes, matikan, tambah dari daftar API provider). Baris bawaan tidak
// pernah ditimpa setelah ada di database.
type Builtin struct {
	Provider  string
	ModelID   string
	Label     string
	ExtraBody string
	Free      bool
}

var Builtins = []Builtin{
	// kenari: model ":free" tetap jalan walau saldo nol. step-3-7-flash tidak
	// bisa mematikan penalaran, jadi diminta seminim mungkin.
	{ProviderKenari, "step-3-7-flash:free", "Step 3.7 Flash (gratis)", `{"reasoning_effort":"low"}`, true},
	{ProviderKenari, "nemotron-3-super-120b-a12b:free", "Nemotron 3 Super 120B (gratis)", "", true},
	// Agnes: matikan thinking supaya token tidak habis sebelum JSON ditulis.
	{ProviderAgnes, "agnes-3.0-flash", "Agnes 3.0 Flash", `{"chat_template_kwargs":{"enable_thinking":false}}`, true},
	{ProviderAgnes, "agnes-2.5-flash", "Agnes 2.5 Flash", "", true},
	// OpenRouter: varian ":free" (id berisi "/" dan ":"). Cek ketersediaannya
	// lewat "Tes" atau "Tambah dari daftar API".
	{ProviderOpenRouter, "qwen/qwen3-235b-a22b:free", "Qwen3 235B A22B (gratis)", `{"reasoning":{"effort":"low"}}`, true},
	{ProviderOpenRouter, "openai/gpt-oss-120b:free", "GPT-OSS 120B (gratis)", `{"reasoning":{"effort":"low"}}`, true},
}
