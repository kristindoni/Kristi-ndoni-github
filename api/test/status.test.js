const request = require('supertest');
const assert = require('assert');
const app = require('../app');

// These tests run against a real Postgres instance, provided as a service
// container in CI (see .gitlab-ci.yml). Locally, export DBUSER/DB/DBPASS/
// DBHOST/DBPORT pointing at any reachable Postgres before running `npm test`.
describe('GET /api/status', function () {
  it('returns 200 with a time and a request_uuid', function (done) {
    request(app)
      .get('/api/status')
      .expect(200)
      .end(function (err, res) {
        if (err) return done(err);
        assert.ok(Array.isArray(res.body), 'response body should be an array');
        assert.ok(res.body[0].time, 'row should contain a time field');
        assert.ok(res.body[0].request_uuid, 'row should contain a request_uuid field');
        done();
      });
  });

  it('returns 404 for unknown routes', function (done) {
    request(app).get('/does-not-exist').expect(404, done);
  });
});
