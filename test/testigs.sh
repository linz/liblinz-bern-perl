#!/bin/bash
mkdir -p output
rm -rf output/*
libdir=../lib
bindir=../bin
perl -I$libdir $bindir/igslog_to_sta -h > output/testigs0.log 2>&1
perl -I$libdir $bindir/igslog_to_sta -P -v -m sitelogs TESTSTA.STA output/TESTIGS1.STA > output/testigs1.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m sitelogs/igs:sitelogs/geonet TESTSTA.STA output/TESTIGS2.STA > output/testigs2.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m sitelogs/geonet:sitelogs/igs TESTSTA.STA output/TESTIGS3.STA > output/testigs3.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -c TESTSTA.CRD sitelogs/geonet:sitelogs/igs TESTSTA.STA output/TESTIGS4.STA > output/testigs4.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -a -c TESTSTA.CRD sitelogs/geonet:sitelogs/igs TESTSTA.STA output/TESTIGS5.STA > output/testigs5.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -a -n -c TESTSTA.CRD sitelogs/geonet:sitelogs/igs TESTSTA.STA output/TESTIGS6.STA > output/testigs6.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -a -n -c TESTSTA.CRD sitelogs/igs:sitelogs/geonet TESTSTA.STA output/TESTIGS7.STA > output/testigs7.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -a -d -c TESTSTA.CRD sitelogs/igs:sitelogs/geonet TESTSTA.STA output/TESTIGS8.STA > output/testigs8.log
perl -I$libdir $bindir/igslog_to_sta -P -v -m -a -d -C TESTSTA.CRD sitelogs/igs:sitelogs/geonet output/TESTIGS9.STA > output/testigs8.log
diff -I 'STATION INFORMATION FILE' output check
