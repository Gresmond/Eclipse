const query = new URLSearchParams(location.search);
const words = {
  expired: 'That sign-in took too long. Try again.',
  cancelled: 'Sign-in was cancelled.',
  google: 'Google couldn’t complete the sign-in. Try again.',
  drive: 'Eclipse needs to keep its files in your Drive. Sign in again and leave that box ticked.',
};
const notice = document.getElementById('notice');
const said = query.get('expired') ? 'Google signed Eclipse out. Sign in again: nothing here has been lost.' : words[query.get('error')];
if (said) {
  notice.textContent = said;
  notice.hidden = false;
  if (query.get('error')) notice.classList.add('error');
}
