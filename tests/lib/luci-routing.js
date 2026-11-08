'use strict';
const fs = require('fs');

module.exports = function(options = {}) {
	return new Function('baseclass', 'ui', 'E', '_', 'L',
		fs.readFileSync('root/www/luci-static/resources/podkopchik/routing.js', 'utf8'))(
		{extend: value => value}, options.ui || {addNotification() {}}, options.E || (() => ({})),
		options.translate || (value => value), {url: (...parts) => '/' + parts.join('/')});
};
