(function () {
  'use strict';
  var form = document.getElementById('savi-software-signup');
  if (!form || !window.fetch || !window.FormData || !window.AbortController) return;
  var button = form.querySelector('button[type="submit"]');
  var status = document.getElementById('savi-software-form-status');
  var success = document.getElementById('savi-software-success');
  var original = button.innerHTML;
  var pending = false;
  form.addEventListener('submit', async function (event) {
    event.preventDefault();
    if (pending || !form.reportValidity()) return;
    pending = true;
    button.disabled = true;
    form.setAttribute('aria-busy', 'true');
    button.textContent = 'Saving your signup…';
    status.textContent = '';
    var data = new FormData(form);
    data.set('ajax', '1');
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 20000);
    try {
      var response = await fetch(form.action, { method: 'POST', body: data, credentials: 'same-origin', signal: controller.signal, headers: { 'Accept': 'application/json' } });
      var result = await response.json();
      if (!response.ok || !result.success) throw new Error(result.data && result.data.message ? result.data.message : 'We could not save your signup. Please try again.');
      form.hidden = true;
      success.hidden = false;
      success.focus();
    } catch (error) {
      status.textContent = error.name === 'AbortError' ? 'The connection timed out. Please try again; your email is still in the form.' : (error instanceof SyntaxError ? 'We could not reach the signup service. Please try again.' : error.message);
      status.classList.add('is-error');
      status.focus();
    } finally {
      clearTimeout(timeout);
      pending = false;
      button.disabled = false;
      button.innerHTML = original;
      form.removeAttribute('aria-busy');
    }
  });
}());
