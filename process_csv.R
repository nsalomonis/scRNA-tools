#!/usr/bin/env Rscript
library(docopt)
"Usage: process_csv OUTPUT_DIR

-h --help    show this

This utility script converts the 'single_cell_software.csv'
spreadsheet to a set of files including:

  - data/software.json
  - data/categories.json
" -> doc

opts <- docopt(doc)
print(opts)

library(readr)
library(jsonlite)
library(dplyr)
library(tidyr)
library(lubridate)
library(stringr)
library(rvest)
library(rcrossref)

#' Create tidy sheet from the google sheet
#' @export
get_swsheet <- function() {
    message("Getting Bioconductor package list...")
    bioc.pkgs <- BiocInstaller::all_group()
    names(bioc.pkgs) <- str_to_lower(bioc.pkgs)

    message("Getting PyPI package list...")
    pypi.pkgs <- read_html("https://pypi.python.org/simple/") %>%
        html_nodes("a") %>%
        html_text()
    names(pypi.pkgs) <- str_to_lower(pypi.pkgs)

    message("Getting CRAN package list...")
    cran.url <- "https://cran.r-project.org/web/packages/available_packages_by_name.html"
    cran.pkgs <- read_html(cran.url) %>%
        html_nodes("a") %>%
        html_text() %>%
        setdiff(LETTERS) # Remove letter links at top of page
    names(cran.pkgs) <- str_to_lower(cran.pkgs)

    message("Processing table...")
    swsheet <- read_csv("single_cell_software.csv",
                        col_types = cols(
                            .default = col_logical(),
                            Name = col_character(),
                            Platform = col_character(),
                            DOI = col_character(),
                            PubDate = col_character(),
                            Code = col_character(),
                            Description = col_character(),
                            License = col_character(),
                            Added = col_date(format = ""),
                            Updated = col_date(format = "")
                            )) %>%
        mutate(Preprint = (PubDate == "PREPRINT")) %>%
        mutate(PubDate = ifelse(Preprint == FALSE, PubDate, NA)) %>%
        mutate(PubDate = as_date(PubDate)) %>%
        mutate(Preprint = ifelse(Preprint == TRUE, TRUE, NA)) %>%
        mutate(DOI_url = ifelse(is.na(DOI), NA,
                                paste0('http://dx.doi.org/', DOI))) %>%
        mutate(Github = ifelse(str_detect(Code, "github"),
                               str_replace(Code, "https://github.com/", ""),
                               NA)) %>%
        mutate(Bioconductor = str_to_lower(Name) %in% names(bioc.pkgs)) %>%
        mutate(Bioconductor = ifelse(Bioconductor,
                                     bioc.pkgs[str_to_lower(Name)], NA)) %>%
        mutate(CRAN = str_to_lower(Name) %in% names(cran.pkgs)) %>%
        mutate(CRAN = ifelse(CRAN, cran.pkgs[str_to_lower(Name)], NA)) %>%
        mutate(CRAN = ifelse(str_detect(Platform, "R"), CRAN, NA)) %>%
        mutate(pypi = str_to_lower(Name) %in% names(pypi.pkgs)) %>%
        mutate(pypi = ifelse(pypi, pypi.pkgs[str_to_lower(Name)], NA)) %>%
        mutate(pypi = ifelse(str_detect(str_to_lower(Platform), "python"),
                             pypi, NA))

    message("Getting citations...")
    swsheet$citations <- get_citations(swsheet$DOI)

    return(swsheet)
}

tidy_swsheet <- function(swsheet) {
    message("Tidying data...")
    gather(swsheet, key = 'category', value = 'val',
           -Description, -Name, -Platform, -DOI, -PubDate, -Updated, -Added,
           -Preprint, -Code, -Github, -DOI_url, -License, -Bioconductor, -pypi,
           -CRAN, -citations) %>%
        filter(val == TRUE) %>%
        select(-val) %>%
        arrange(Name)
}

get_citations <- function(dois) {

    cites <- sapply(dois, function(doi) {
        if (is.na(doi)) {
            return(NA)
        }

        cit <-  tryCatch({
            cr_citation_count(doi)
        }, error = function(e) {
            NA
        })

        Sys.sleep(sample(seq(0,2,0.5), 1))

        return(cit)
    })

    return(cites)
}

tidysw_to_list_df <- function(tidysw) {
    catlist <- split(tidysw$category, f = tidysw$Name)
    tidyswl <- tidysw %>%
        select(-category) %>%
        unique()
    tidyswl[['categories']] <- catlist[tidyswl$Name]
    tidyswl
}

tidysw_to_cat_df <- function(tidysw, swsheet) {
    namelist <- split(tidysw$Name, f = tidysw$category)
    namelist <- lapply(namelist, function(x) {
        swsheet %>%
            filter(Name %in% x) %>%
            select(Name, Bioconductor, CRAN, pypi)
    })
    tidyswl <- tidysw %>%
        select(category) %>%
        arrange(category) %>%
        unique()
    tidyswl[['software']] <- namelist[tidyswl$category]
    tidyswl
}

add_cats_column <- function(swsheet, tidysw) {
    catlist <- split(tidysw$category, f = tidysw$Name)

    catdf <- data.frame(Name = names(catlist), stringsAsFactors = FALSE)
    catdf[['categories']] <- catlist

    swsheet <- left_join(swsheet, catdf, by = "Name")
}

#' write out json and csv files
#'
#' @export
write_files <- function(destdir) {
  dir.create(destdir, recursive = TRUE)
  swsheet <- get_swsheet()
  tidysw <- tidy_swsheet(swsheet)
  #write_csv(swsheet,path=file.path(destdir,'single-cell-software_tidy.csv'))
  swsheet <- add_cats_column(swsheet, tidysw)
  writeLines(toJSON(swsheet, pretty = TRUE),
             file.path(destdir, 'software-table.json'))
  writeLines(toJSON(tidysw_to_list_df(tidysw), pretty = TRUE),
             file.path(destdir, 'software.json'))
  writeLines(toJSON(tidysw_to_cat_df(tidysw, swsheet), pretty = TRUE),
             file.path(destdir, 'categories.json'))
}

write_files(opts$OUTPUT_DIR)
