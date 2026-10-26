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
    button.textContent = 'Preparing your download…';
    status.textContent = '';
    var data = new FormData(form);
    data.set('ajax', '1');
    var controller = new AbortController();
    var timeout = setTimeout(function () { controller.abort(); }, 20000);
    try {
      var response = await fetch(form.getAttribute('action'), { method: 'POST', body: data, credentials: 'same-origin', signal: controller.signal, headers: { 'Accept': 'application/json' } });
      var result = await response.json();
      if (!response.ok || !result.success) throw new Error(result.data && result.data.message ? result.data.message : 'We could not save your signup. Please try again.');
      var updateStatus = result.data && result.data.updates ? result.data.updates : (result.data && result.data.subscribed ? 'joined' : 'not-added');
      var eyebrow = success.querySelector('.savi-software-eyebrow');
      var heading = success.querySelector('h3');
      var message = success.querySelector('p:not(.savi-software-eyebrow):not(.savi-software-small)');
      if (eyebrow) eyebrow.textContent = updateStatus === 'pending' ? 'SAV LAB / CONFIRM SOFTWARE UPDATES' : (updateStatus === 'joined' ? 'SAV LAB / UPDATES JOINED' : 'SAV LAB / DOWNLOAD READY');
      if (heading) heading.textContent = updateStatus === 'pending' ? 'Check your inbox.' : (updateStatus === 'joined' ? 'You’re on the updates list.' : 'Koala Link is ready.');
      if (message) {
        if (updateStatus === 'pending') message.textContent = 'Your download is ready now. Follow MailerLite’s confirmation email to receive software updates.';
        else if (updateStatus === 'joined') message.textContent = 'Your download is ready, and your email is on the software updates list.';
        else if (updateStatus === 'sync-error') message.textContent = 'Your download is ready, but we could not complete the software updates signup. You can try again using the form.';
        else message.textContent = 'Your download is ready. Your address has not been added to the updates list.';
      }
      form.hidden = updateStatus !== 'sync-error';
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
