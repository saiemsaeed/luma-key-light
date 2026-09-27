const $ = (selector) => document.querySelector(selector);
const ui = {
  hero: $('#heroCard'), power: $('#powerButton'), powerLabel: $('#powerLabel'),
  brightness: $('#brightness'), brightnessValue: $('#brightnessValue'),
  temperature: $('#temperature'), temperatureValue: $('#temperatureValue'),
  connection: $('#connectionText'), details: $('#details'), toast: $('#toast')
};

const model = { on: false, brightness: 20, kelvin: 4300, connected: false, busy: false };
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

render();
refresh();
setInterval(() => refresh(true), 3000);
