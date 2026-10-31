package ai

// NewRegistryForTest mengarahkan semua provider ke baseURL (mis. httptest)
// dengan key palsu dan tanpa allowlist host. Hanya untuk tes paket lain; tidak
// bisa diaktifkan lewat konfigurasi.
func NewRegistryForTest(baseURL string) *Registry {
	r := NewRegistry(func(k string) string {
		if len(k) > 8 && k[len(k)-8:] == "_API_KEY" {
			return "test-key"
		}
		return ""
	})
	for _, p := range r.providers {
		p.BaseURL = baseURL
	}
	r.allowHost = func(*Provider, string) bool { return true }
	return r
}
