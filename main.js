var cheerio = require('cheerio');
var fs = require('fs');
var mu = require('mu2');
var redis = require('redis');
var request = require('request');
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

        .alias('dc', 'dataload-concurrent-batches')
        .describe('dc', 'The number of concurrent batches that were loaded.')
        .default('dc', 1)

        .alias('dd', 'dataload-duration')
        .describe('dd', 'How load it took the load the batches into the system (in ms).')
        .default('dd', 1)

        .alias('dr', 'dataload-requests')
        .describe('dr', 'The number of requests to load up all the batches.')
        .default('dr', 1)

        .alias('tr', 'tsung-report')
        .describe('tr', 'The relative location of the tsung report.')
        .default('tr', './tsung/report.html');




var pushToCirconus = function(data, callback) {
    request({
            'method': 'PUT',
            'uri': 'https://trap.noit.circonus.net/module/httptrap/5655b0c9-5246-68b3-e456-edfb512d4ea1/mys3cr3t',
            'body': JSON.stringify(data)
        }, callback);
};


/**
 * Converts a duration in seconds to a pretty string.
 * @param  {Number} duration The duration in seconds.
 * @return {String}          The duration as a string.
 *                           ex: 1500 would be converted to 25m 0s.
 */
var prettyTime = function(duration) {
    var seconds = duration;
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

/**
 * Converts a string to milliseconds.
 * @param  {String} str A string of the form '32sec'
 * @return {Number}     The amount of time in milliseconds.
 */
var stringToMillis = function(str) {
    // Convert it to a number
    var value = parseFloat(str);
    // Get it in ms.
    if (str.split(' ')[1] === 'sec') {
        value *= 1000;
    } else if (str.split(' ')[1] === 'mn') {
        value *= 60000;
    }
    return value;
};



var argv = optimist.argv;

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
stats.dataload.concurrentBatches = argv['dataload-concurrent-batches'];
stats.dataload.requestsPerSecond = stats.dataload.requests / (argv['dataload-duration']);



// Get some stats from Cassandra.
stats.cassandra = {};
var client = redis.createClient(6379, '165.225.133.113');
client.hget('telemetry', 'cassandra.read', function(err, data) {
    stats.cassandra.reads = data;
});
client.hget('telemetry', 'cassandra.write', function(err, data) {
    stats.cassandra.writes = data;
});


// Parse the tsung stats.
stats.tsung = {};
stats.tsung.report = argv['tsung-report'];
var tsungHTML = fs.readFileSync(stats.tsung.report, 'UTF-8');
var $ = cheerio.load(tsungHTML);


// Get the highest rate of requests/sec
var rows = $('div#stats table.stats').find('tr');
stats.tsung.highestRate = parseFloat(rows["3"].children[7].children[0].data);
stats.tsung.meanRequestTime = stringToMillis(rows["3"].children[9].children[0].data);

stats.tsung.transactions = {};
var transactionRows = $('div#transaction table.stats').find('tr');
for (var i = 1; i < transactionRows.length;i++) {
    var name = transactionRows["" + i].children[1].children[0].data;
    var highestTenMean = transactionRows["" + i].children[3].children[0].data;
    var mean = transactionRows["" + i].children[9].children[0].data;
    stats.tsung.transactions[name] = {
        'mean': mean,
        'highestTenMean': highestTenMean
    };
}

stats.tsung.codes = {};
var codes = [200, 201, 401, 404, 500, 502];
for (var i = 0; i < codes.length; i++) {
    var row = $('td:contains("' + codes[i] + '")')['0'];
    if (row) {
        var rate = parseFloat(row.next.next.children[0].data);
        var counts = parseInt(row.next.next.next.next.children[0].data, 10);
        stats.tsung.codes[codes[i]] = {
            'rate': rate,
            'counts': counts
        };
    }
}

// The data we wish to push to circonus
var circonusData = {
    'nightly': {
        'codes': {},
        'highestRate': {'_type': 'n', '_value': stats.tsung.highestRate},
        'meanRequestTime': {'_type': 'n', '_value': stats.tsung.meanRequestTime}
    }
};
for (var code in stats.tsung.codes) {
    circonusData.nightly.codes[code] = {
        'rate': {'_type': 'n', '_value': stats.tsung.codes[code].rate},
        'counts': {'_type': 'n', '_value': stats.tsung.codes[code].counts}
    };
}
circonusData.nightly.codes[500] = {
        'rate': {'_type': 'n', '_value': 20},
        'counts': {'_type': 'n', '_value': 30}
    };


setTimeout(function() {
    // Generate a pretty HTML file with moustache.
    mu.root = __dirname + '/templates'
    mu.compileAndRender('stats.html', stats)
        .on('data', function (data) {
            console.log(data.toString());
        })
        .on('end', function() {
            // Push stuff to Circonus
            pushToCirconus(circonusData, function(err, response, body) {
                process.exit();
            });
        });
}, 2000);

