var express = require('express');
var router = express.Router();
var request = require('request');


var api_url = process.env.API_HOST + '/api/status';

/* GET home page. */
router.get('/', function(req, res, next) {
    request({
            method: 'GET',
            url: api_url,
            json: true,
            headers: {
                // The api call is routed through the same WAF-protected
                // Application Gateway as public traffic (via its internal
                // frontend). OWASP CRS flags a missing User-Agent and a
                // numeric-IP Host header as anomalous - both true by
                // default for a bare server-to-server call by IP. Set them
                // explicitly rather than weakening the WAF for everyone.
                'User-Agent': 'node-3tier-app2-web/1.0',
                'Host': 'api.internal.n3t-prod.local'
            }
        },
        function(error, response, body) {
            if (error || response.statusCode !== 200) {
                return res.status(500).send('error running request to ' + api_url);
            } else {
                res.render('index', {
                    title: '3tier App',
                    request_uuid: body[0].request_uuid,
                    time: body[0].time
                });
            }
        }
    );
});

module.exports = router;