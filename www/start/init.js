var statusElement = document.getElementById("status"),
	progressElement = document.getElementById("progress"),
	spinnerElement = document.getElementById("spinner"),
	toggleOutputElement = document.getElementById("toggle-output"),
	Module = {
		print: function () {
			var e = document.getElementById("output"); return e && (e.value = ""), (...t) => {
				var n = t.join(" "); console.log(n), e && (e.value += n + "\n", e.scrollTop = e.scrollHeight)
			}
		}(),
		canvas: (() => {
			var e = document.getElementById("canvas"); return e.addEventListener("webglcontextlost", (e => { alert("WebGL context lost. You will need to reload the page."), e.preventDefault() }), !1), e
		}
		)(),
		setStatus: e => {
			if (Module.setStatus.last ??= { time: Date.now(), text: "" }, e !== Module.setStatus.last.text) {
				var t = e.match(/([^(]+)\((\d+(\.\d+)?)\/(\d+)\)/), n = Date.now();
				t && n - Module.setStatus.last.time < 30 || (
					Module.setStatus.last.time = n,
					Module.setStatus.last.text = e,
					t ? (e = t[1], progressElement.value = 100 * parseInt(t[2]), progressElement.max = 100 * parseInt(t[4]), progressElement.hidden = !1, spinnerElement.hidden = !1) : (progressElement.value = null, progressElement.max = null, progressElement.hidden = !0, e || (spinnerElement.style.display = "none")),
					statusElement.innerHTML = e
				)
			}
		},
		totalDependencies: 0,
		monitorRunDependencies: e => {
			this.totalDependencies = Math.max(this.totalDependencies, e), Module.setStatus(e ? "Preparing... (" + (this.totalDependencies - e) + "/" + this.totalDependencies + ")" : "All downloads complete.")
		}
	};
Module.setStatus("Downloading..."),
	window.onerror = e => {
		Module.setStatus("Exception thrown, see JavaScript console"),
			spinnerElement.style.display = "none",
			Module.setStatus = e => {
				e && console.error("[post-exception status] " + e)
			}
	}

// Handle console toggler button:
toggleOutputElement.addEventListener('change', (e) => {
	const output = document.querySelector('#output');
	output.classList.toggle('invisible', !e.target.checked);
});

