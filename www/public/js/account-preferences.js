(function () {
  'use strict';

  function initializePreferences(form) {
    const city = form.querySelector('#hall');
    const group = form.querySelector('#home-station');
    const line = form.querySelector('#home-station-line');
    const station = form.querySelector('#home-station-id');
    const options = station ? Array.from(station.options).map(option => option.cloneNode(true)) : [];

    function update() {
      const supported = city.selectedOptions[0]?.dataset.network === 'mbta';
      group.hidden = !supported;
      if (!line || !station) return;
      if (!supported) line.value = '';
      const previous = station.value;
      const available = options.filter(option =>
        !option.value || (supported && option.dataset.routes.split(' ').includes(line.value)));
      station.replaceChildren(...available.map(option => option.cloneNode(true)));
      station.value = available.some(option => option.value === previous) ? previous : '';
      // Keep the blank value submitted so clearing a line also clears its station.
      station.disabled = false;
    }

    city.addEventListener('change', update);
    if (line) line.addEventListener('change', update);
    update();
  }

  if (typeof module !== 'undefined') module.exports = { initializePreferences };
  if (typeof document !== 'undefined') {
    const form = document.querySelector('#preference-form');
    if (form) initializePreferences(form);
  }
}());
