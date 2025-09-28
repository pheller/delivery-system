	var Module = typeof Module != 'undefined' ? Module : {};

	Module['expectedDataFileDownloads'] ??= 0;
	Module['expectedDataFileDownloads']++;
	(() => {
		// Do not attempt to redownload the virtual filesystem data when in a pthread or a Wasm Worker context.
		var isPthread = typeof ENVIRONMENT_IS_PTHREAD != 'undefined' && ENVIRONMENT_IS_PTHREAD;
		var isWasmWorker = typeof ENVIRONMENT_IS_WASM_WORKER != 'undefined' && ENVIRONMENT_IS_WASM_WORKER;
		if (isPthread || isWasmWorker) return;
		var isNode = typeof process === 'object' && typeof process.versions === 'object' && typeof process.versions.node === 'string';
		function loadPackage(metadata) {

			var PACKAGE_PATH = '';
			if (typeof window === 'object') {
				PACKAGE_PATH = window['encodeURIComponent'](window.location.pathname.substring(0, window.location.pathname.lastIndexOf('/')) + '/');
			} else if (typeof process === 'undefined' && typeof location !== 'undefined') {
				// web worker
				PACKAGE_PATH = encodeURIComponent(location.pathname.substring(0, location.pathname.lastIndexOf('/')) + '/');
			}
			var PACKAGE_NAME = '/Users/pheller/Projects/em-dosbox/src/prodigy-6.03.17.data';
			var REMOTE_PACKAGE_BASE = 'prodigy-6.03.17.data';
			var REMOTE_PACKAGE_NAME = Module['locateFile'] ? Module['locateFile'](REMOTE_PACKAGE_BASE, '') : REMOTE_PACKAGE_BASE;
			var REMOTE_PACKAGE_SIZE = metadata['remote_package_size'];

			function fetchRemotePackage(packageName, packageSize, callback, errback) {
				if (isNode) {
					require('fs').readFile(packageName, (err, contents) => {
						if (err) {
							errback(err);
						} else {
							callback(contents.buffer);
						}
					});
					return;
				}
				Module['dataFileDownloads'] ??= {};
				fetch(packageName)
					.catch((cause) => Promise.reject(new Error(`Network Error: ${packageName}`, { cause }))) // If fetch fails, rewrite the error to include the failing URL & the cause.
					.then((response) => {
						if (!response.ok) {
							return Promise.reject(new Error(`${response.status}: ${response.url}`));
						}

						if (!response.body && response.arrayBuffer) { // If we're using the polyfill, readers won't be available...
							return response.arrayBuffer().then(callback);
						}

						const reader = response.body.getReader();
						const iterate = () => reader.read().then(handleChunk).catch((cause) => {
							return Promise.reject(new Error(`Unexpected error while handling : ${response.url} ${cause}`, { cause }));
						});

						const chunks = [];
						const headers = response.headers;
						const total = Number(headers.get('Content-Length') ?? packageSize);
						let loaded = 0;

						const handleChunk = ({ done, value }) => {
							if (!done) {
								chunks.push(value);
								loaded += value.length;
								Module['dataFileDownloads'][packageName] = { loaded, total };

								let totalLoaded = 0;
								let totalSize = 0;

								for (const download of Object.values(Module['dataFileDownloads'])) {
									totalLoaded += download.loaded;
									totalSize += download.total;
								}

								Module['setStatus']?.(`Downloading data... (${totalLoaded}/${totalSize})`);
								return iterate();
							} else {
								const packageData = new Uint8Array(chunks.map((c) => c.length).reduce((a, b) => a + b, 0));
								let offset = 0;
								for (const chunk of chunks) {
									packageData.set(chunk, offset);
									offset += chunk.length;
								}
								callback(packageData.buffer);
							}
						};

						Module['setStatus']?.('Downloading data...');
						return iterate();
					});
			};

			function handleError(error) {
				console.error('package error:', error);
			};

			var fetchedCallback = null;
			var fetched = Module['getPreloadedPackage'] ? Module['getPreloadedPackage'](REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE) : null;

			if (!fetched) fetchRemotePackage(REMOTE_PACKAGE_NAME, REMOTE_PACKAGE_SIZE, (data) => {
				if (fetchedCallback) {
					fetchedCallback(data);
					fetchedCallback = null;
				} else {
					fetched = data;
				}
			}, handleError);

			function runWithFS(Module) {

				function assert(check, msg) {
					if (!check) throw msg + new Error().stack;
				}

				/** @constructor */
				function DataRequest(start, end, audio) {
					this.start = start;
					this.end = end;
					this.audio = audio;
				}
				DataRequest.prototype = {
					requests: {},
					open: function (mode, name) {
						this.name = name;
						this.requests[name] = this;
						Module['addRunDependency'](`fp ${this.name}`);
					},
					send: function () { },
					onload: function () {
						var byteArray = this.byteArray.subarray(this.start, this.end);
						this.finish(byteArray);
					},
					finish: function (byteArray) {
						var that = this;
						// canOwn this data in the filesystem, it is a slide into the heap that will never change
						Module['FS_createDataFile'](this.name, null, byteArray, true, true, true);
						Module['removeRunDependency'](`fp ${that.name}`);
						this.requests[this.name] = null;
					}
				};

				var files = metadata['files'];
				for (var i = 0; i < files.length; ++i) {
					new DataRequest(files[i]['start'], files[i]['end'], files[i]['audio'] || 0).open('GET', files[i]['filename']);
				}

				function processPackageData(arrayBuffer) {
					assert(arrayBuffer, 'Loading data file failed.');
					assert(arrayBuffer.constructor.name === ArrayBuffer.name, 'bad input to processPackageData');
					var byteArray = new Uint8Array(arrayBuffer);
					var curr;
					// Reuse the bytearray from the XHR as the source for file reads.
					DataRequest.prototype.byteArray = byteArray;
					var files = metadata['files'];
					for (var i = 0; i < files.length; ++i) {
						DataRequest.prototype.requests[files[i].filename].onload();
					} Module['removeRunDependency']('datafile_/Users/pheller/Projects/em-dosbox/src/prodigy-6.03.17.data');

				};
				Module['addRunDependency']('datafile_/Users/pheller/Projects/em-dosbox/src/prodigy-6.03.17.data');

				Module['preloadResults'] ??= {};

				Module['preloadResults'][PACKAGE_NAME] = { fromCache: false };
				if (fetched) {
					processPackageData(fetched);
					fetched = null;
				} else {
					fetchedCallback = processPackageData;
				}

			}
			if (Module['calledRun']) {
				runWithFS(Module);
			} else {
				(Module['preRun'] ??= []).push(runWithFS); // FS is not initialized yet, wait for it
			}

		}
		loadPackage({ "files": [{ "filename": "/CACHE.DAT", "start": 0, "end": 61440 }, { "filename": "/CLUB.BAT", "start": 61440, "end": 61768 }, { "filename": "/CONFIG.SM", "start": 61768, "end": 61963 }, { "filename": "/DRIVER.SCR", "start": 61963, "end": 73623 }, { "filename": "/EGA320.SCR", "start": 73623, "end": 85777 }, { "filename": "/EGA640.SCR", "start": 85777, "end": 97437 }, { "filename": "/HUFFMAN.DAT", "start": 97437, "end": 101525 }, { "filename": "/INS_ICON.TRX", "start": 101525, "end": 101563 }, { "filename": "/KEYS.TRX", "start": 101563, "end": 102587 }, { "filename": "/LOG_KEYS.TRX", "start": 102587, "end": 102785 }, { "filename": "/MTRES.EXE", "start": 102785, "end": 110587 }, { "filename": "/MTSHUT.EXE", "start": 110587, "end": 112863 }, { "filename": "/NOT_ENUF.BAT", "start": 112863, "end": 113868 }, { "filename": "/PRODIGY.BAT", "start": 113868, "end": 114196 }, { "filename": "/RELOAD.BAT", "start": 114196, "end": 114510 }, { "filename": "/RS.EXE", "start": 114510, "end": 301531 }, { "filename": "/STAGE.DAT", "start": 301531, "end": 501595 }, { "filename": "/STARTUTL.EXE", "start": 501595, "end": 508614 }, { "filename": "/TLFD0000", "start": 508614, "end": 508681 }, { "filename": "/VAN.Y", "start": 508681, "end": 508790 }, { "filename": "/VDIPLP.TTX", "start": 508790, "end": 580343 }, { "filename": "/WAIT.BAT", "start": 580343, "end": 580667 }, { "filename": "/WAITICON.TRX", "start": 580667, "end": 580739 }, { "filename": "/XTG00010.DAT", "start": 580739, "end": 581739 }, { "filename": "/dosbox.conf", "start": 581739, "end": 581805 }], "remote_package_size": 581805 });

	})();

	Module['arguments'] = ['./PRODIGY.BAT'];
