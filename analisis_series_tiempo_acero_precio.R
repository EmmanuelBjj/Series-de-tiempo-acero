#####################################
# Series de tiempo: precios de hierro y acero (millones de pesos)
# Serie trimestral. Flujo: exploración -> estacionariedad -> modelos ->
# evaluación fuera de muestra -> diagnóstico -> pronóstico.
#
# Importante: los datos vienen ordenados del más reciente al más antiguo.
# El primer paso es ordenarlos de forma cronológica antes de crear el objeto ts.
#####################################

# install.packages(c("tidyverse", "readxl", "forecast", "tseries", "openxlsx"))
library(tidyverse)
library(readxl)
library(forecast)
library(tseries)
library(openxlsx)

dir.create("figuras",    showWarnings = FALSE)
dir.create("resultados", showWarnings = FALSE)

# 1. DATOS ---------------------------------------------------------------
ruta <- "acero_precio_mdp.xlsx"

datos <- read_excel(ruta) %>%
  rename(Mes = Month, Anio = Year, Valor = `Precios de hierro y acero (mdp)`) %>%
  arrange(Anio, Mes) %>%                                   # orden cronológico
  mutate(Fecha = as.Date(paste(Anio, Mes, "01", sep = "-")))

# La serie debe ser trimestral y sin huecos (Mes = 3, 6, 9, 12)
stopifnot(all(diff(datos$Anio * 12 + datos$Mes) == 3))

# Mes 3 = trimestre 1, mes 6 = trimestre 2, etc.
serie <- ts(datos$Valor,
            start = c(datos$Anio[1], datos$Mes[1] / 3),
            frequency = 4)

cat("Periodo:", start(serie), "a", end(serie), "| observaciones:", length(serie), "\n")
print(summary(datos$Valor))

# 2. EXPLORACIÓN ---------------------------------------------------------
g1 <- ggplot(datos, aes(Fecha, Valor)) +
  geom_line(color = "steelblue", linewidth = 0.9) +
  labs(title = "Precios de hierro y acero", x = "Fecha", y = "Millones de pesos") +
  theme_minimal()
ggsave("figuras/01_serie.png", g1, width = 9, height = 5.5, dpi = 150)

g2 <- ggsubseriesplot(serie) +
  labs(title = "Valor promedio por trimestre", x = "Trimestre", y = "Millones de pesos") +
  theme_minimal()
ggsave("figuras/02_estacionalidad.png", g2, width = 9, height = 5.5, dpi = 150)

descomp <- stl(serie, s.window = "periodic")
ggsave("figuras/03_descomposicion_stl.png", autoplot(descomp) + theme_minimal(),
       width = 9, height = 7, dpi = 150)

comp <- descomp$time.series
fuerza_estacional <- max(0, 1 - var(comp[, "remainder"]) /
                              var(comp[, "seasonal"] + comp[, "remainder"]))
cat("Fuerza de la estacionalidad (0 = nula, 1 = muy fuerte):", round(fuerza_estacional, 3), "\n")
cat("Rango del componente estacional:", round(range(comp[, "seasonal"])), "\n")

# 3. ESTACIONARIEDAD -----------------------------------------------------
cat("\n--- Serie original ---\n")
print(adf.test(serie))     # H0: no estacionaria
print(kpss.test(serie))    # H0: estacionaria
cat("Diferencias regulares necesarias:", ndiffs(serie), "\n")
cat("Diferencias estacionales necesarias:", nsdiffs(serie), "\n")

dif1 <- diff(serie)
cat("\n--- Serie diferenciada una vez ---\n")
print(adf.test(dif1))
print(kpss.test(dif1))

png("figuras/04_acf_pacf_diferenciada.png", width = 1400, height = 600, res = 150)
par(mfrow = c(1, 2))
Acf(dif1, main = "ACF (serie diferenciada)")
Pacf(dif1, main = "PACF (serie diferenciada)")
dev.off()

# 4. ENTRENAMIENTO Y PRUEBA ---------------------------------------------
fin_entrenamiento <- c(2019, 4)   # último trimestre de entrenamiento
inicio_prueba     <- c(2020, 1)   # primer trimestre de prueba

tr <- window(serie, end   = fin_entrenamiento)
te <- window(serie, start = inicio_prueba)
h  <- length(te)
cat("\nEntrenamiento:", length(tr), "trimestres | Prueba:", h, "trimestres\n")

# Etiqueta legible del orden de un modelo ARIMA, por ejemplo "ARIMA(1,1,1)"
etiqueta_arima <- function(fit) {
  o <- arimaorder(fit)
  txt <- if (length(o) == 7) {
    sprintf("ARIMA(%d,%d,%d)(%d,%d,%d)[%d]", o[1], o[2], o[3], o[4], o[5], o[6], o[7])
  } else {
    sprintf("ARIMA(%d,%d,%d)", o[1], o[2], o[3])
  }
  if ("drift" %in% names(coef(fit))) txt <- paste(txt, "con deriva")
  txt
}

# 5. MODELOS -------------------------------------------------------------
# Cada modelo es una función (serie, horizonte) -> pronóstico
modelos <- list(
  "Ingenuo"                 = function(x, h) naive(x, h = h),
  "Ingenuo estacional"      = function(x, h) snaive(x, h = h),
  "SARIMA(1,1,1)(1,0,1)[4]" = function(x, h) forecast(Arima(x, order = c(1, 1, 1), seasonal = c(1, 0, 1), method = "ML"), h = h),
  "SARIMA(2,1,1)(1,0,1)[4]" = function(x, h) forecast(Arima(x, order = c(2, 1, 1), seasonal = c(1, 0, 1), method = "ML"), h = h),
  "SARIMA(1,1,2)(1,0,1)[4]" = function(x, h) forecast(Arima(x, order = c(1, 1, 2), seasonal = c(1, 0, 1), method = "ML"), h = h),
  "auto.arima"              = function(x, h) forecast(auto.arima(x, stepwise = FALSE, approximation = FALSE), h = h),
  "ETS"                     = function(x, h) forecast(ets(x), h = h)
)

# 5a. Criterios de información (solo modelos ARIMA, ajustados con el entrenamiento)
ajustes <- list(
  "SARIMA(1,1,1)(1,0,1)[4]" = Arima(tr, order = c(1, 1, 1), seasonal = c(1, 0, 1), method = "ML"),
  "SARIMA(2,1,1)(1,0,1)[4]" = Arima(tr, order = c(2, 1, 1), seasonal = c(1, 0, 1), method = "ML"),
  "SARIMA(1,1,2)(1,0,1)[4]" = Arima(tr, order = c(1, 1, 2), seasonal = c(1, 0, 1), method = "ML"),
  "auto.arima"              = auto.arima(tr, stepwise = FALSE, approximation = FALSE)
)

criterios <- tibble(
  Modelo = names(ajustes),
  Orden  = map_chr(ajustes, etiqueta_arima),
  AIC    = map_dbl(ajustes, AIC),
  AICc   = map_dbl(ajustes, ~ .x$aicc),
  BIC    = map_dbl(ajustes, BIC)
) %>% arrange(AICc) %>% mutate(across(c(AIC, AICc, BIC), ~ round(.x, 1)))

cat("\n--- Criterios de información (menor es mejor) ---\n")
print(criterios)

mejor_nombre <- criterios$Modelo[1]
mejor_ajuste <- ajustes[[mejor_nombre]]
cat("Modelo con menor AICc:", mejor_nombre, "->", etiqueta_arima(mejor_ajuste), "\n")

# 5b. Evaluación en el tramo de prueba (holdout)
holdout <- map_dfr(names(modelos), function(nombre) {
  a <- accuracy(modelos[[nombre]](tr, h), te)["Test set", ]
  tibble(Modelo = nombre, MAE = a["MAE"], RMSE = a["RMSE"], MAPE = a["MAPE"], MASE = a["MASE"])
}) %>% arrange(RMSE) %>% mutate(across(where(is.numeric), ~ round(.x, 2)))

cat("\n--- Tramo de prueba (", h, " trimestres hacia adelante) ---\n", sep = "")
print(holdout)

# 5c. Validación hacia adelante (se reajusta el modelo en cada origen)
hacia_adelante <- map_dfr(names(modelos), function(nombre) {
  e <- tsCV(serie, modelos[[nombre]], h = 4, initial = 60)
  tibble(Modelo   = nombre,
         MAE_h1   = mean(abs(e[, 1]), na.rm = TRUE),
         RMSE_h1  = sqrt(mean(e[, 1]^2, na.rm = TRUE)),
         MAE_h4   = mean(abs(e[, 4]), na.rm = TRUE),
         RMSE_h4  = sqrt(mean(e[, 4]^2, na.rm = TRUE)))
}) %>% arrange(RMSE_h1) %>% mutate(across(where(is.numeric), ~ round(.x, 0)))

cat("\n--- Validación hacia adelante (h = 1 y h = 4 trimestres) ---\n")
print(hacia_adelante)

write.xlsx(list("Criterios" = criterios, "Tramo de prueba" = holdout, "Hacia adelante" = hacia_adelante),
           "resultados/comparacion_modelos.xlsx", overwrite = TRUE)
write_csv(holdout, "resultados/tramo_de_prueba.csv")
write_csv(hacia_adelante, "resultados/hacia_adelante.csv")
write_csv(criterios, "resultados/criterios_informacion.csv")

# 6. DIAGNÓSTICO DEL MODELO SELECCIONADO ----------------------------------
res <- residuals(mejor_ajuste)

cat("\n--- Diagnóstico de residuos:", etiqueta_arima(mejor_ajuste), "---\n")
print(Box.test(res, lag = 8, type = "Ljung-Box", fitdf = length(mejor_ajuste$coef)))  # H0: sin autocorrelación
print(shapiro.test(res))                                                            # H0: normalidad

png("figuras/05_residuos.png", width = 1400, height = 1000, res = 150)
checkresiduals(mejor_ajuste)
dev.off()

png("figuras/06_qqplot_residuos.png", width = 1000, height = 800, res = 150)
qqnorm(res, main = "Gráfico Q-Q de los residuos")
qqline(res)
dev.off()

# 7. PRONÓSTICOS DEL TRAMO DE PRUEBA VS. OBSERVADO ---------------------------
mostrar <- c("Ingenuo", mejor_nombre, "SARIMA(1,1,1)(1,0,1)[4]", "ETS")
mostrar <- unique(mostrar)

pron <- map_dfr(mostrar, function(nombre) {
  tibble(Modelo = nombre,
         Tiempo = as.numeric(time(te)),
         Pronostico = as.numeric(modelos[[nombre]](tr, h)$mean))
})
real <- tibble(Tiempo = as.numeric(time(serie)), Valor = as.numeric(serie))

g7 <- ggplot() +
  geom_line(data = real, aes(Tiempo, Valor), linewidth = 1, color = "grey30") +
  geom_line(data = pron, aes(Tiempo, Pronostico, color = Modelo), linewidth = 0.9) +
  geom_vline(xintercept = as.numeric(time(te))[1], linetype = "dashed") +
  labs(title = "Pronóstico del tramo de prueba vs. valores observados",
       subtitle = "Modelos ajustados solo con datos hasta 2019 T4 (línea punteada = inicio de la prueba)",
       x = "Año", y = "Millones de pesos") +
  theme_minimal()
ggsave("figuras/07_pronostico_tramo_prueba.png", g7, width = 9, height = 5.5, dpi = 150)

# 8. PRONÓSTICO FINAL (modelo reajustado con toda la serie) -------------------
orden <- arimaorder(mejor_ajuste)
modelo_final <- if (length(orden) == 7) {
  Arima(serie, order = orden[1:3], seasonal = list(order = orden[4:6], period = orden[7]), method = "ML")
} else {
  Arima(serie, order = orden[1:3], method = "ML")
}

fc_final <- forecast(modelo_final, h = 8, level = c(80, 95))
print(fc_final)

g8 <- autoplot(fc_final) +
  labs(title = paste("Pronóstico a 8 trimestres:", etiqueta_arima(modelo_final)),
       subtitle = "Intervalos del 80 % y 95 %",
       x = "Año", y = "Millones de pesos") +
  scale_x_continuous(breaks = seq(1995, 2025, by = 5)) +
  theme_minimal()
ggsave("figuras/08_pronostico_final.png", g8, width = 9, height = 5.5, dpi = 150)

write_csv(as_tibble(fc_final) %>% mutate(across(everything(), ~ round(.x, 1))),
          "resultados/pronostico_final.csv")

# NOTAS --------------------------------------------------------------------
# - Compara siempre contra el modelo ingenuo: si un modelo más complejo no lo supera,
#   no aporta valor para pronosticar.
# - Los errores de pronóstico a varios trimestres son grandes porque la serie tiene
#   cambios bruscos de nivel; los intervalos de confianza lo reflejan.
