const $ = (selector) => document.querySelector(selector);
const ui = {
  hero: $('#heroCard'), power: $('#powerButton'), powerLabel: $('#powerLabel'),
  brightness: $('#brightness'), brightnessValue: $('#brightnessValue'),
  temperature: $('#temperature'), temperatureValue: $('#temperatureValue'),
  connection: $('#connectionText'), details: $('#details'), toast: $('#toast'),
  deviceSelect: $('#deviceSelect'), discover: $('#discoverButton')
};

const model = { on: false, brightness: 20, kelvin: 4300, connected: false, busy: false, devices: [] };
let toastTimer;
let interactingUntil = 0;

function miredToKelvin(value) { return Math.round(1000000 / value / 50) * 50; }
function kelvinToMired(value) { return clamp(Math.round(1000000 / value), 143, 344); }
function clamp(value, min, max) { return Math.min(max, Math.max(min, value)); }

function lightColor(kelvin) {
  const t = clamp((kelvin - 2900) / 4100, 0, 1);
  const warm = [255, 177, 91], neutral = [255, 238, 205], cool = [190, 221, 255];
  const a = t < .58 ? warm : neutral;
  const b = t < .58 ? neutral : cool;
  const p = t < .58 ? t / .58 : (t - .58) / .42;
  return `rgb(${a.map((v, i) => Math.round(v + (b[i] - v) * p)).join(',')})`;
}

function render() {
  ui.hero.classList.toggle('on', model.on);
  ui.powerLabel.textContent = model.on ? 'ON' : 'OFF';
  ui.brightness.value = model.brightness;
  ui.brightnessValue.textContent = `${model.brightness}%`;
  ui.brightness.style.setProperty('--progress', `${(model.brightness - 3) / 97 * 100}%`);
  ui.temperature.value = model.kelvin;
  ui.temperatureValue.textContent = `${model.kelvin.toLocaleString()} K`;
  document.documentElement.style.setProperty('--light-color', lightColor(model.kelvin));
  const enabled = model.connected && !model.busy;
  ui.power.disabled = !enabled;
  ui.brightness.disabled = !model.connected;
  ui.temperature.disabled = !model.connected;
  document.body.classList.toggle('connected', model.connected);
  document.body.classList.toggle('error', !model.connected);
  ui.connection.textContent = model.connected ? 'Connected' : 'Offline';
}

async function fetchJSON(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: { 'Content-Type': 'application/json', ...(options.headers || {}) }
  });
  const text = await response.text();
  if (!response.ok) {
    const error = new Error(text || `Request failed (${response.status})`);
    error.status = response.status;
    throw error;
  }
  return text ? JSON.parse(text) : {};
}

async function refresh(silent = false) {
  if (Date.now() < interactingUntil) return;
  try {
    const data = await fetchJSON('/api/state');
    const light = data.lights?.[0];
    if (!light) throw new Error('No light returned');
    model.on = light.on === 1;
    model.brightness = light.brightness;
    model.kelvin = clamp(miredToKelvin(light.temperature), 2900, 7000);
    model.connected = true;
    render();
  } catch (error) {
    model.connected = false;
    render();
    if (!silent) showToast('Could not reach the light');
  }
}

async function sendState(changes) {
  interactingUntil = Date.now() + 1200;
  try {
    const light = {};
    if ('on' in changes) light.on = changes.on ? 1 : 0;
    if ('brightness' in changes) light.brightness = Math.round(changes.brightness);
    if ('kelvin' in changes) light.temperature = kelvinToMired(changes.kelvin);
    const data = await fetchJSON('/api/state', {
      method: 'PUT', body: JSON.stringify({ numberOfLights: 1, lights: [light] })
    });
    const returned = data.lights?.[0];
    if (returned) {
      model.on = returned.on === 1;
      model.brightness = returned.brightness;
      model.kelvin = clamp(miredToKelvin(returned.temperature), 2900, 7000);
    }
    model.connected = true;
    render();
  } catch (error) {
    model.connected = error.status != null;
    render();
    showToast(error.status === 400 ? 'The light rejected that setting' : 'Change failed — light is offline');
  }
}

ui.power.addEventListener('click', async () => {
  model.busy = true;
  model.on = !model.on;
  render();
  await sendState({ on: model.on });
  model.busy = false;
  render();
});

ui.brightness.addEventListener('input', (event) => {
  model.brightness = Number(event.target.value);
  interactingUntil = Date.now() + 5000;
  render();
});
ui.brightness.addEventListener('change', () => sendState({ brightness: model.brightness }));

ui.temperature.addEventListener('input', (event) => {
  model.kelvin = Number(event.target.value);
  interactingUntil = Date.now() + 5000;
  render();
});
ui.temperature.addEventListener('change', () => sendState({ kelvin: model.kelvin }));

document.querySelectorAll('.scene').forEach((button) => button.addEventListener('click', () => {
  model.on = true;
  model.brightness = Number(button.dataset.brightness);
  model.kelvin = Number(button.dataset.kelvin);
  render();
  sendState({ on: true, brightness: model.brightness, kelvin: model.kelvin });
}));

function deviceKey(device) {
  return device.id || `${device.host}:${device.port}`;
}

async function selectDiscoveredDevice(device) {
  return fetchJSON('/api/devices/select', {
    method: 'POST',
    body: JSON.stringify({ id: device.id || null, host: device.host, port: device.port })
  });
}

async function discoverLights(silent = false) {
  ui.discover.disabled = true;
  ui.deviceSelect.disabled = true;
  try {
    // Read provenance before scanning: an explicit --host must always beat a
    // browser-local remembered choice.
    const config = await fetchJSON('/api/config');
    const devices = await fetchJSON('/api/devices');
    const rememberedId = localStorage.getItem('lumaDeviceId');
    const remembered = !config.hostExplicit && rememberedId
      ? devices.find((device) => device.id === rememberedId)
      : null;
    if (remembered && !remembered.selected) {
      await selectDiscoveredDevice(remembered);
      for (const device of devices) device.selected = deviceKey(device) === deviceKey(remembered);
    }

    const selected = devices.find((device) => device.selected);
    // Establish a preference on first use, but never replace an existing one
    // merely because its device missed a transient scan.
    if (!rememberedId && selected?.id) localStorage.setItem('lumaDeviceId', selected.id);
    model.devices = devices;
    ui.deviceSelect.replaceChildren();

    if (!selected) {
      const option = document.createElement('option');
      option.value = '';
      option.textContent = config.hostExplicit
        ? `Configured · ${config.host}:${config.port}`
        : (devices.length ? 'Current configured light' : 'No Key Lights found');
      option.selected = true;
      ui.deviceSelect.append(option);
    }
    for (const device of devices) {
      const option = document.createElement('option');
      option.value = deviceKey(device);
      option.textContent = device.name || device.model || device.host;
      option.selected = device.selected;
      ui.deviceSelect.append(option);
    }

    if (!silent) showToast(devices.length === 1 ? 'Found 1 Key Light' : `Found ${devices.length} Key Lights`);
    return devices;
  } catch (error) {
    model.devices = [];
    ui.deviceSelect.replaceChildren();
    const option = document.createElement('option');
    option.textContent = 'Discovery unavailable';
    ui.deviceSelect.append(option);
    if (!silent) showToast('Could not scan for Key Lights');
    return [];
  } finally {
    ui.discover.disabled = false;
    ui.deviceSelect.disabled = model.devices.length === 0;
  }
}

ui.deviceSelect.addEventListener('change', async () => {
  const key = ui.deviceSelect.value;
  if (key === '') return;
  ui.deviceSelect.disabled = true;
  try {
    const selected = model.devices.find((device) => deviceKey(device) === key);
    if (!selected) throw new Error('Selected light is no longer available');
    await selectDiscoveredDevice(selected);
    if (selected.id) localStorage.setItem('lumaDeviceId', selected.id);
    for (const device of model.devices) device.selected = deviceKey(device) === key;
    interactingUntil = 0;
    model.connected = false;
    render();
    await refresh();
    await loadDetails();
    showToast('Key Light selected');
  } catch (error) {
    showToast('Could not select that light');
    await discoverLights(true);
  } finally {
    ui.deviceSelect.disabled = false;
  }
});

ui.discover.addEventListener('click', async () => {
  await discoverLights(false);
  interactingUntil = 0;
  await refresh(true);
  await loadDetails();
});

function setDetails(open) {
  ui.details.classList.toggle('open', open);
  ui.details.setAttribute('aria-hidden', String(!open));
  if (open) loadDetails();
}
$('#settingsButton').addEventListener('click', () => setDetails(true));
$('#closeDetails').addEventListener('click', () => setDetails(false));
$('#detailsScrim').addEventListener('click', () => setDetails(false));
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') setDetails(false); });

async function loadDetails() {
  try {
    const [info, config] = await Promise.all([fetchJSON('/api/info'), fetchJSON('/api/config')]);
    $('#infoModel').textContent = info.productName || 'Key Light';
    $('#deviceName').textContent = info.displayName || 'Studio Light';
    $('#infoFirmware').textContent = info.firmwareVersion || '—';
    $('#infoWifi').textContent = info['wifi-info']?.ssid || '—';
    const rssi = info['wifi-info']?.rssi;
    $('#infoSignal').textContent = rssi == null ? '—' : `${rssi} dBm · ${rssi >= -60 ? 'Great' : rssi >= -70 ? 'Good' : 'Weak'}`;
    $('#infoAddress').textContent = `${config.host}:${config.port}`;
  } catch (error) { showToast('Device details unavailable'); }
}

$('#identifyButton').addEventListener('click', async () => {
  try { await fetchJSON('/api/identify', { method: 'POST', body: '{}' }); showToast('Light identified'); }
  catch (error) { showToast('Identify is not supported by this firmware'); }
});

function showToast(message) {
  clearTimeout(toastTimer);
  ui.toast.textContent = message;
  ui.toast.classList.add('show');
  toastTimer = setTimeout(() => ui.toast.classList.remove('show'), 2600);
}

async function initialize() {
  render();
  await discoverLights(true);
  await refresh();
}

initialize();
setInterval(() => refresh(true), 3000);
