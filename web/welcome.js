const query = new URLSearchParams(location.search);
const words = {
  expired: 'That sign-in took too long. Try again.',
  cancelled: 'Sign-in was cancelled.',
  google: 'Google couldn’t complete the sign-in. Try again.',
  drive: 'Eclipse needs to keep its files in your Drive. Sign in again and leave that box ticked.',
  erase: 'Signed out, though this browser wouldn’t let Eclipse finish erasing its local data.',
};
const notice = document.getElementById('notice');
const err = query.get('error');
const said = query.get('expired')
  ? 'Google signed Eclipse out. Sign in again: nothing here has been lost.'
  : query.get('offline_signout')
    ? 'This browser’s copy was erased, though Eclipse couldn’t reach the server to end your sign-in there while offline.'
    : err && Object.hasOwn(words, err)
      ? words[err]
      : undefined;
if (said) {
  notice.textContent = said;
  notice.hidden = false;
  if (err || query.get('offline_signout')) notice.classList.add('error');
}
