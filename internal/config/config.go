package config

import "os"

type Config struct {
	AppName          string
	Environment      string
	Port             string
	LogLevel         string
	Version          string
	GitSHA           string
	BuildTime        string
	FeatureCacheWarm bool
}

func Load() Config {
	return Config{
		AppName:          getEnv("APP_NAME", "release-api"),
		Environment:      getEnv("APP_ENV", "dev"),
		Port:             getEnv("APP_PORT", "8080"),
		LogLevel:         getEnv("LOG_LEVEL", "info"),
		Version:          getEnv("APP_VERSION", "dev"),
		GitSHA:           getEnv("GIT_SHA", "local"),
		BuildTime:        getEnv("BUILD_TIME", "unknown"),
		FeatureCacheWarm: getEnv("FEATURE_CACHE_WARM", "true") == "true",
	}
}

func getEnv(key, fallback string) string {
	value := os.Getenv(key)
	if value == "" {
		return fallback
	}
	return value
}
