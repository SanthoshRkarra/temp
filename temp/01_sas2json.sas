
%macro sas2json(
    in_lib=,          /* Required: Path to the input SAS library containing the dataset */
    dataset=,         /* Required: Name of the SAS dataset to convert */
    out_lib=,         /* Required: Path to the output directory for the JSON file */
    out_json=,        /* Optional: Name of the output JSON file. Defaults to <dataset>.json */
    compare=NO,       /* Optional: Whether to perform PROC COMPARE. Options: YES or NO. Defaults to NO */
    debug=NO          /* Optional: Enable detailed debugging. Options: YES or NO. Defaults to NO */
);
    /*
    ------------------------------------------------------------------------
    Macro: sas2json
    ------------------------------------------------------------------------
    Description:
        Converts a SAS dataset to a JSON file, including metadata.
        Optionally enables debugging for detailed macro execution tracing.
    
    Parameters:
        in_lib    - (Required) Path to the input SAS library containing the dataset.
        dataset   - (Required) Name of the SAS dataset to convert.
        out_lib   - (Required) Path to the output directory for the JSON file.
        out_json  - (Optional) Name of the output JSON file. Defaults to <dataset>.json.
        compare   - (Optional) Whether to perform PROC COMPARE after conversion.
                    Valid values: YES or NO. Defaults to NO.
        debug     - (Optional) Enable detailed macro debugging.
                    Valid values: YES or NO. Defaults to NO.
    
    Usage Example:
        %sas2json(
            in_lib=C:\Projects\macrolib\SAS2JSON\in,
            dataset=class,
            out_lib=C:\Projects\macrolib\SAS2JSON\out
        );
    ------------------------------------------------------------------------
    */

    /* ----------------------------
       1. Validate Required Parameters
    ---------------------------- */
    %if %length(&in_lib) = 0 or
        %length(&dataset) = 0 or
        %length(&out_lib) = 0 %then %do;
        %put ERROR: Missing required parameters. Please provide in_lib, dataset, and out_lib.;
        %return;
    %end;

    /* ----------------------------
       2. Set Default for out_json if Not Provided
    ---------------------------- */
    %if %length(&out_json) = 0 %then %do;
        %let out_json=&dataset..json;
    %end;

    /* ----------------------------
       3. Enable or Disable Macro Debugging
    ---------------------------- */
    %if %upcase(&debug) = YES %then %do;
        options mprint mlogic symbolgen;
        %put NOTE: Macro debugging is ENABLED.;
    %end;
    %else %do;
        options nomprint nomlogic nosymbolgen;
        %put NOTE: Macro debugging is DISABLED.;
    %end;

    /* ----------------------------
       4. Assign Librefs
    ---------------------------- */
    libname in "&in_lib";
    libname out "&out_lib";

    /* ----------------------------
       5. Create a Dataset with the Metadata
    ---------------------------- */
    proc contents data=in.&dataset out=meta_data noprint;
    run;

    /* ----------------------------
       6. Extract Dataset Label
    ---------------------------- */
    proc sql noprint;
        select memlabel into :memlabel trimmed
        from dictionary.tables
        where libname = upcase("IN") and memname = upcase("&dataset");
    quit;

    /* ----------------------------
       7. Define the JSON Output File Path
    ---------------------------- */
    filename outjson "&out_lib.\&out_json";

    /* ----------------------------
       8. Export Metadata to JSON
    ---------------------------- */
    data _null_;
        set meta_data end=eof_meta;
        file outjson lrecl=32767;
        retain header_written 0;

        /* Write JSON header and metadata */
        if _n_ = 1 then do;
            put '{';
            put '  "dataset_label": "' "&memlabel" '",';
            put '  "metadata": [';
        end;

        /* Rename TYPE to VAR_TYPE to avoid conflicts */
        VAR_TYPE = type;
        meta_name = name;

        /* Write each metadata entry */
        put '    {';
        put '      "name": "' meta_name +(-1) '",';
        put '      "type": ' VAR_TYPE ',';
        put '      "length": ' length ',';
        put '      "format": "' format +(-1) '",';
        put '      "informat": "' informat +(-1) '",';
        put '      "label": "' label +(-1) '",';
        put '      "varnum": ' varnum;
        if not eof_meta then
            put '    },';
        else
            put '    }';

        /* After metadata, start data array */
        if eof_meta then do;
            put '  ],';
            put '  "data": [';
        end;
    run;

    /* ----------------------------
       9. Export Data to JSON
    ---------------------------- */
    data _null_;
        set in.&dataset end=eof_data;
        file outjson mod lrecl=32767; /* 'mod' to append to the existing file */

        /* Dynamically write each observation as JSON object */
        put '    {';

        /* Dynamically write each variable */
        length varname $32 value $32767;
        array char_vars {*} _character_;
        array num_vars {*} _numeric_;
        total_vars = dim(char_vars) + dim(num_vars);
        idx = 1;

        /* Process Character Variables */
        do j = 1 to dim(char_vars);
            varname = vname(char_vars{j});
            /* Escape double quotes in the value */
            value = tranwrd(strip(char_vars{j}), '"', '\"');
            value = cats('"', value, '"');
            if idx < total_vars then
                put '      "' varname +(-1) '": ' value ',';
            else
                put '      "' varname +(-1) '": ' value;
            idx + 1;
        end;

        /* Process Numeric Variables */
        do j = 1 to dim(num_vars);
            varname = vname(num_vars{j});
            if missing(num_vars{j}) then
                value = 'null';
            else
                value = strip(put(num_vars{j}, best.));
            if idx < total_vars then
                put '      "' varname +(-1) '": ' value ',';
            else
                put '      "' varname +(-1) '": ' value;
            idx + 1;
        end;

        /* Close JSON Object */
        if not eof_data then
            put '    },';
        else
            put '    }';

        /* After last observation, close data array and JSON */
        if eof_data then do;
            put '  ]';
            put '}';
        end;
    run;

    /* ----------------------------
       10. Clear Librefs and Filenames
    ---------------------------- */
    libname in clear;
    libname out clear;
    filename outjson clear;

    /* ----------------------------
       11. Inform Completion
    ---------------------------- */
    %put NOTE: JSON file "&out_lib.\&out_json" has been successfully created from dataset in.&dataset..;

    /* ----------------------------
       12. Optional: Compare Original and JSON Reconstructed Dataset
    ---------------------------- */
    %if %upcase(&compare) = YES %then %do;
        /*
           Note: To perform a meaningful comparison, you need to reconstruct the SAS
           dataset from the JSON file first.
           This typically involves another macro (e.g., %json2sas) that reads the JSON
           file and creates a SAS dataset.
    
           Assuming you have such a macro, you can call it here to reconstruct the dataset
           into a different library (e.g., reconstructed_lib), and then perform PROC COMPARE
           between the original and reconstructed datasets.
        */

        /* Example Placeholder for Reconstruction */
        /*
        %json2sas(
            in_lib=&in_lib,
            json_lib=&out_lib,
            out_lib=C:\Projects\macrolib\SAS2JSON\reconstructed,
            dataset=&dataset,
            out_json=&out_json,
            debug=&debug
        );
        */

        /* Placeholder PROC COMPARE assuming reconstruction is done */
        /*
        proc compare base=in.&dataset compare=reconstructed.&dataset listall method=exact;
        run;
        */

        /* Since reconstruction is not implemented here, we'll skip the comparison */
        %put NOTE: Comparison step is skipped because reconstruction from JSON is not implemented.;
    %end;
    %else %do;
        %put NOTE: Comparison step is skipped as per the compare parameter.;
    %end;

%mend sas2json;


%sas2json(
    in_lib=C:\Projects\macrolib\SAS2JSON\in,
    dataset=cars,
    out_lib=C:\Projects\macrolib\SAS2JSON\out,
    out_json=cars.json,
    compare=NO,
    debug=YES
);



/*%sas2json(*/
/*    in_lib=C:\Projects\macrolib\SAS2JSON\in,*/
/*    dataset=class,*/
/*    out_lib=C:\Projects\macrolib\SAS2JSON\out,*/
/*    out_json=class.json,*/
/*    compare=NO,*/
/*    debug=YES*/
/*);*/
/**/
