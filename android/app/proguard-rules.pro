# Room builds the implementation name from WorkDatabase and calls its no-arg
# constructor through reflection while Android initializes WorkManager.
-keep class androidx.work.impl.WorkDatabase { *; }
-keep class androidx.work.impl.WorkDatabase_Impl { public <init>(); }
