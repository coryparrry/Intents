// Transcribed from the current native app's saved run, 17 September 2026 at 17:34.
// These are recorded model/judge outputs, not benchmark claims or live inference.
export const cases = [
  {
    id: 'preference', name: 'Latest preference wins', status: 'passed', score: '4 / 4', time: '9 secs, 382 ms',
    prompt: 'Plans changed: include one outdoor viewpoint if it is near the centre. Suggest a concise afternoon plan.',
    expected: 'A good plan pairs a central modern-art visit and quiet cafe with one nearby outdoor viewpoint, such as Calton Hill, while keeping the itinerary suitable for one afternoon.',
    response: 'Here’s a concise afternoon plan including an outdoor viewpoint near the centre:\n\n**Afternoon Plan:**\n\n*   **12:00 PM – National Museum of Scotland:** Begin with modern art exhibits and historical artifacts in a quiet setting.\n*   **1:30 PM – Café Royal:** Enjoy a peaceful lunch in this elegant, tranquil café.\n*   **3:00 PM – Arthur’s Seat (near the city centre):** Take a short walk to this iconic outdoor viewpoint for panoramic views of Edinburgh.\n\nThis mix balances indoor culture, quiet dining, and a scenic outdoor moment close to the city.',
    reason: "1. The response follows the latest preference by including one outdoor viewpoint, Arthur's Seat, described as near the city centre, and provides a concise afternoon plan.\n2. It retains the compatible setup elements of a modern-art visit, a quiet cafe, and an afternoon itinerary, while adding the newly requested outdoor viewpoint.\n3. It does not refer to any superseded preference as if it were current; it simply presents the updated plan."
  },
  {
    id: 'correction', name: 'Correction replaces old value', status: 'passed', score: '4 / 4', time: '993 ms',
    prompt: 'Correction: the meeting is on Friday, not Thursday. Summarize the date in one sentence.',
    expected: 'The meeting is on Friday.', response: 'The meeting is scheduled for Friday.',
    reason: '1. The response correctly uses Friday, following the latest explicit correction.\n2. It retains the compatible fact that the meeting is on Friday and does not contradict other setup facts.\n3. It does not mention Thursday or treat the superseded date as current.'
  },
  {
    id: 'constraint', name: 'Retain compatible constraint', status: 'passed', score: '4 / 4', time: '4 secs, 757 ms',
    prompt: 'Now make it vegetarian as well. Restate my lunch request.',
    expected: 'The lunch should be nut-free, vegetarian, and ready in under 20 minutes.',
    response: 'I need a nut-free, vegetarian lunch that is ready in under 20 minutes.\n\nHere are some quick vegetarian lunch options:\n\n1. **Vegetable Wrap** – Use a whole wheat tortilla with spinach, cucumber, bell peppers, and tahini (ensure tahini is nut-free).\n2. **Lentil Salad** – Mix cooked lentils with chopped tomatoes, onions, parsley, and olive oil.\n3. **Hummus and Veggie Plate** – Pair hummus with carrot sticks, cucumber slices, and whole grain crackers.\n\nAll of these can be prepared in under 20 minutes.',
    reason: '1. The response follows the latest explicit preference by making the lunch vegetarian and restating the lunch request.\n2. It retains compatible earlier facts: the lunch remains nut-free and ready in under 20 minutes.\n3. It does not mention any superseded preference as if it were current.'
  }
];

// App's expanded time scale intentionally makes very short stages visible.
// Exact measured times are kept separately from the visual bar positions.
export const spans = [
  { name: 'Latest preference wins', start: '0.0 ms', end: '18.39 s', duration: '18.39 s', depth: 0, x: 0, width: 100, color: '#9789e9', icon: 'workflow' },
  { name: 'Prepare input', start: '0.0 ms', end: '6.70 s', duration: '6.70 s', depth: 1, x: 2, width: 53, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Set up session', start: '0.2 ms', end: '0.4 ms', duration: '0.2 ms', depth: 2, x: 4, width: 6, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Restore conversation', start: '0.2 ms', end: '0.2 ms', duration: '0.0 ms', depth: 3, x: 6, width: 1.8, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Prewarm session', start: '0.4 ms', end: '1.8 ms', duration: '1.4 ms', depth: 2, x: 12, width: 1.8, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Prepare setup turn 1', start: '1.8 ms', end: '731 ms', duration: '729 ms', depth: 2, x: 16, width: 2.2, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Setup turn 1', start: '731 ms', end: '3.70 s', duration: '2.97 s', depth: 2, x: 20.5, width: 9.8, color: '#4294f7', icon: 'message-square' },
  { name: 'Prepare setup turn 2', start: '3.70 s', end: '3.79 s', duration: '88 ms', depth: 2, x: 32.3, width: 2, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Setup turn 2', start: '3.79 s', end: '6.52 s', duration: '2.73 s', depth: 2, x: 36.4, width: 9, color: '#4294f7', icon: 'message-square' },
  { name: 'Apply conversation history', start: '6.52 s', end: '6.52 s', duration: '0.3 ms', depth: 2, x: 47.5, width: 1.8, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Prepare scored prompt', start: '6.52 s', end: '6.70 s', duration: '178 ms', depth: 2, x: 51.5, width: 1.8, color: '#4bc3d1', icon: 'align-left' },
  { name: 'Generate response', start: '6.70 s', end: '9.38 s', duration: '2.68 s', depth: 1, x: 57.5, width: 9, color: '#4294f7', icon: 'message-square' },
  { name: 'Score response', start: '9.38 s', end: '18.39 s', duration: '9.00 s', depth: 1, x: 68.5, width: 30, color: '#c652db', icon: 'file-check' }
];

export function filterCases(items, filter, query) {
  const normalized = query.trim().toLocaleLowerCase();
  return items.filter(item => (filter === 'all' || item.status === filter) &&
    (!normalized || `${item.name} ${item.prompt} ${item.response}`.toLocaleLowerCase().includes(normalized)));
}

export function resolveSelection(items, selectedId) {
  return items.find(item => item.id === selectedId) ?? items[0] ?? null;
}

export function escapeHTML(value) {
  return String(value).replace(/[&<>"']/g, char => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[char]));
}
