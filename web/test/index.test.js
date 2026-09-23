process.env.API_HOST = 'http://api.test';

const nock = require('nock');
const request = require('supertest');
const app = require('../app');

describe('GET /', function () {
  afterEach(function () {
    nock.cleanAll();
  });

  it('renders the page when the API responds', function (done) {
    nock('http://api.test')
      .get('/api/status')
      .reply(200, [{ time: '2024-01-01T00:00:00Z', request_uuid: 'abc-123' }]);

    request(app)
      .get('/')
      .expect(200)
      .expect(function (res) {
        if (!res.text.includes('abc-123')) {
          throw new Error('expected response to include request_uuid from API');
        }
      })
      .end(done);
  });

  it('returns 500 when the API is unreachable', function (done) {
    nock('http://api.test').get('/api/status').replyWithError('connection refused');

    request(app).get('/').expect(500, done);
  });
});
