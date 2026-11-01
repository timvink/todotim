# kotlinx.serialization ships R8 rules in its jar; these keep the generated serializers of our @Serializable
# classes (db.json) explicitly, so a shrinker change cannot silently break loading the database.
-keepclassmembers @kotlinx.serialization.Serializable class app.todotim.** {
    *** Companion;
    static ** INSTANCE;
    kotlinx.serialization.KSerializer serializer(...);
}
-keep,includedescriptorclasses class app.todotim.**$$serializer { *; }
-keepattributes RuntimeVisibleAnnotations,AnnotationDefault,InnerClasses,Signature

# Core is compiled against kxml2 for the JVM; on Android, XmlPullParser comes from the platform.
-dontwarn org.kxml2.**
