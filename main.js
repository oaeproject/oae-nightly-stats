var mu = require('mu2');
var redis = require('redis');
var optimist = require('optimist')
        .usage('Usage: $0')

        .alias('h', 'help')
        .describe('h', 'Show this help information.')

        .alias('b', 'batches')
        .describe('b', 'If using source data, this specifies how many batches of that data should be aggregated into CSV.')
        .default('b', 1)

        .alias('u', 'users-per-batch')
        .describe('u', 'The amount of users in a group.')
        .default('u', 1000)

        .alias('g', 'groups-per-batch')
        .describe('g', 'The amount of groups in a batch.')
        .default('g', 2000)

        .alias('c', 'content-per-batch')
        .describe('c', 'The amount of content items in a batch.')
        .default('c', 5000)

        .alias('gd', 'generation-duration')
        .describe('gd', 'How long it took to generate the batches (in ms).')
        .default('gd', 1)

        .alias('dd', 'dataload-duration')
        .describe('dd', 'How load it took the load the batches into the system (in ms).')
        .default('dd', 1)

        .alias('dr', 'dataload-requests')
        .describe('dr', 'The number of requests to load up all the batches.')
        .default('dr', 1)

        .alias('tr', 'tsung-report')
        .describe('tr', 'The relative location of the tsung report.')
        .default('tr', './tsung/report.html');


var argv = optimist.argv;

/**
 * Converts a duration in ms to a pretty string.
 * @param  {Number} duration The duration in ms.
 * @return {String}          The duration as a string.
 *                           ex: 1500 would be converted to 1.5 seconds.
 */
var prettyTime = function(duration) {
    var seconds = Math.round(duration / 1000);
    var minutes = null;
    var hours = null;
    if (seconds > 60) {
        minutes = Math.round(seconds / 60);
        seconds = seconds % 60;
    }
    if (minutes > 60) {
        hours = Math.round(minutes / 60);
        minutes = minutes % 60;
    }
    
    var str = seconds + "s";
    if (minutes) { 
        str = minutes + "m " + str;
    }
    if (hours) { 
        str = hours + "h " + str;
    }
    return str;
};


// Get the stats
var stats = {};
stats.generation = {};
stats.generation.batches = argv.batches;
stats.generation.usersPerBatch = argv['users-per-batch'];
stats.generation.groupsPerBatch = argv['groups-per-batch'];
stats.generation.contentPerBatch = argv['content-per-batch'];
stats.generation.duration = prettyTime(argv['generation-duration']);

stats.dataload = {};
stats.dataload.duration = prettyTime(argv['dataload-duration']);
stats.dataload.requests = argv['dataload-requests'];
stats.dataload.requestsPerSecond = stats.dataload.requests / (argv['dataload-duration'] / 1000);

stats.tsung = {};
stats.tsung.report = argv['tsung-report'];


// Get some stats from Cassandra.
stats.cassandra = {};
var client = redis.createClient(6379, '165.225.133.113');
client.hget('telemetry', 'cassandra.read', function(err, data) {
    stats.cassandra.reads = data;
});
client.hget('telemetry', 'cassandra.write', function(err, data) {
    stats.cassandra.writes = data;
});


setTimeout(function() {
    // Generate a pretty HTML file with moustache.
    mu.root = __dirname + '/templates'
    mu.compileAndRender('stats.html', stats)
        .on('data', function (data) {
            console.log(data.toString());
        })
        .on('end', function() {
            process.exit(0);
        });
}, 2000);